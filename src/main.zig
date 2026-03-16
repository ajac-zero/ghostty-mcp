const std = @import("std");
const posix = std.posix;
const zmx = @import("zmx.zig");

const MCP_PROTOCOL_VERSION_LATEST = "2025-06-18";
const MCP_PROTOCOL_VERSION_INTERMEDIATE = "2025-03-26";
const MCP_PROTOCOL_VERSION_LEGACY = "2024-11-05";

const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    MCP_PROTOCOL_VERSION_LATEST,
    MCP_PROTOCOL_VERSION_INTERMEDIATE,
    MCP_PROTOCOL_VERSION_LEGACY,
};

const RpcError = struct {
    code: i64,
    message: []const u8,
};

const ToolCallContext = struct {
    alloc: std.mem.Allocator,
    cfg: zmx.Config,
};

const MessageFraming = enum {
    newline,
    content_length,
};

const InboundFrame = struct {
    body: []u8,
    framing: MessageFraming,
};

const ParamDef = struct {
    name: []const u8,
    type_name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    params: []const ParamDef = &.{},
};

const TOOLS = [_]ToolDef{
    .{
        .name = "create_session",
        .description = "Create a zmx session by name and optionally run an initial command.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .description = "Session name", .required = true },
            .{ .name = "command", .type_name = "string", .description = "Optional initial command" },
        },
    },
    .{
        .name = "input_text",
        .description = "Send raw text bytes into a zmx session.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
            .{ .name = "text", .type_name = "string", .required = true },
        },
    },
    .{
        .name = "send_key",
        .description = "Send a keypress to a session (named keys or single character with optional modifiers).",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
            .{ .name = "key", .type_name = "string", .required = true },
            .{ .name = "modifiers", .type_name = "string", .description = "Comma-separated: control,shift,option,command" },
        },
    },
    .{
        .name = "read_output",
        .description = "Read terminal history for a session.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
            .{ .name = "format", .type_name = "string", .description = "plain|vt|html" },
        },
    },
    .{
        .name = "run_command",
        .description = "Execute a shell command in a session and wait for daemon Ack. Supply wait_for to block until a pattern appears in new output.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
            .{ .name = "command", .type_name = "string", .required = true },
            .{ .name = "wait_for", .type_name = "string", .description = "Pattern to wait for in new terminal output before returning" },
            .{ .name = "timeout_ms", .type_name = "integer", .description = "Max milliseconds to wait for the pattern (default 30000)" },
        },
    },
    .{
        .name = "wait_session",
        .description = "Poll session task state until completion (or timeout).",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
            .{ .name = "timeout_ms", .type_name = "integer" },
        },
    },
    .{
        .name = "list_sessions",
        .description = "List discoverable zmx sessions from socket directory.",
    },
    .{
        .name = "kill_session",
        .description = "Kill a session process and detach clients.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
        },
    },
    .{
        .name = "close_session",
        .description = "Compatibility alias for kill_session.",
        .params = &.{
            .{ .name = "name", .type_name = "string", .required = true },
        },
    },
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    var cfg = try zmx.resolveConfig(alloc);
    defer cfg.deinit(alloc);

    const tools_list = try buildToolsListResult(alloc);
    defer alloc.free(tools_list);

    var inbound = try std.ArrayList(u8).initCapacity(alloc, 8192);
    defer inbound.deinit(alloc);

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &chunk);

        if (n == 0) {
            break;
        }

        try inbound.appendSlice(alloc, chunk[0..n]);

        while (true) {
            const maybe_frame = try popFramedMessage(alloc, &inbound);
            if (maybe_frame == null) break;

            const frame = maybe_frame.?;
            defer alloc.free(frame.body);

            const maybe_response = try handleMessage(alloc, cfg, tools_list, frame.body);
            if (maybe_response) |response| {
                defer alloc.free(response);
                try writeMcpFrame(posix.STDOUT_FILENO, alloc, response, frame.framing);
            }
        }
    }
}

fn handleMessage(alloc: std.mem.Allocator, cfg: zmx.Config, tools_list: []const u8, body: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return try buildErrorResponse(alloc, "null", .{ .code = -32700, .message = "Parse error" });
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return try buildErrorResponse(alloc, "null", .{ .code = -32600, .message = "Invalid Request" });
    }

    const obj = root.object;
    const id_value = obj.get("id");
    const id_json = try idValueToJson(alloc, id_value);
    defer alloc.free(id_json);

    const method = getStringFromObject(obj, "method") orelse {
        return try buildErrorResponse(alloc, id_json, .{ .code = -32600, .message = "Missing method" });
    };

    if (std.mem.eql(u8, method, "initialized") or std.mem.eql(u8, method, "notifications/initialized")) {
        return null;
    }

    if (std.mem.eql(u8, method, "ping")) {
        if (id_value == null) return null;
        return try buildSuccessResponse(alloc, id_json, "{}");
    }

    if (std.mem.eql(u8, method, "initialize")) {
        if (id_value == null) return null;

        const protocol_version = negotiateProtocolVersion(obj);

        const result = try std.fmt.allocPrint(
            alloc,
            "{{\"protocolVersion\":\"{s}\",\"serverInfo\":{{\"name\":\"ghostty-mcp-zig\",\"version\":\"0.1.0\"}},\"capabilities\":{{\"tools\":{{}}}}}}",
            .{protocol_version},
        );
        defer alloc.free(result);

        return try buildSuccessResponse(alloc, id_json, result);
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        if (id_value == null) return null;
        return try buildSuccessResponse(alloc, id_json, tools_list);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        if (id_value == null) return null;

        const params = obj.get("params") orelse {
            return try buildErrorResponse(alloc, id_json, .{ .code = -32602, .message = "tools/call missing params" });
        };
        if (params != .object) {
            return try buildErrorResponse(alloc, id_json, .{ .code = -32602, .message = "tools/call params must be object" });
        }

        const params_obj = params.object;
        const tool_name = getStringFromObject(params_obj, "name") orelse {
            return try buildErrorResponse(alloc, id_json, .{ .code = -32602, .message = "tools/call missing name" });
        };

        const args_obj = if (params_obj.get("arguments")) |arguments| blk: {
            if (arguments == .object) break :blk arguments.object;
            return try buildErrorResponse(alloc, id_json, .{ .code = -32602, .message = "tools/call arguments must be object" });
        } else null;

        const ctx = ToolCallContext{ .alloc = alloc, .cfg = cfg };
        const tool_result = dispatchTool(ctx, tool_name, args_obj) catch |err| {
            const err_msg = try std.fmt.allocPrint(alloc, "tool call failed: {s}", .{@errorName(err)});
            defer alloc.free(err_msg);
            return try buildErrorResponse(alloc, id_json, .{ .code = -32000, .message = err_msg });
        };
        defer alloc.free(tool_result);

        return try buildSuccessResponse(alloc, id_json, tool_result);
    }

    if (id_value == null) {
        return null;
    }
    return try buildErrorResponse(alloc, id_json, .{ .code = -32601, .message = "Method not found" });
}

fn dispatchTool(ctx: ToolCallContext, tool_name: []const u8, args: ?std.json.ObjectMap) ![]u8 {
    if (std.mem.eql(u8, tool_name, "create_session")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const initial_command = getStringArg(args, "command");

        try zmx.ensureSessionExists(ctx.alloc, ctx.cfg, name);
        if (initial_command) |cmd| {
            try zmx.runCommand(ctx.alloc, ctx.cfg, name, cmd);
        }

        const msg = if (initial_command) |cmd|
            try std.fmt.allocPrint(ctx.alloc, "Created session '{s}' and ran initial command: {s}", .{ name, cmd })
        else
            try std.fmt.allocPrint(ctx.alloc, "Created session '{s}'.", .{name});
        defer ctx.alloc.free(msg);

        return toolTextResult(ctx.alloc, msg);
    }

    if (std.mem.eql(u8, tool_name, "input_text")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const text = getStringArg(args, "text") orelse return error.MissingText;

        try zmx.sendInput(ctx.cfg, ctx.alloc, name, text);

        const msg = try std.fmt.allocPrint(ctx.alloc, "Sent input to '{s}'.", .{name});
        defer ctx.alloc.free(msg);
        return toolTextResult(ctx.alloc, msg);
    }

    if (std.mem.eql(u8, tool_name, "send_key")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const key = getStringArg(args, "key") orelse return error.MissingKey;
        const modifiers = getStringArg(args, "modifiers");

        const key_bytes = try keyToInputBytes(ctx.alloc, key, modifiers);
        defer ctx.alloc.free(key_bytes);

        try zmx.sendInput(ctx.cfg, ctx.alloc, name, key_bytes);

        const msg = try std.fmt.allocPrint(ctx.alloc, "Sent key '{s}' to '{s}'.", .{ key, name });
        defer ctx.alloc.free(msg);
        return toolTextResult(ctx.alloc, msg);
    }

    if (std.mem.eql(u8, tool_name, "read_output")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const format_text = getStringArg(args, "format") orelse "plain";
        const format = zmx.historyFormatFromString(format_text);

        const output = try zmx.readHistory(ctx.cfg, ctx.alloc, name, format);
        defer ctx.alloc.free(output);

        return toolTextResult(ctx.alloc, output);
    }

    if (std.mem.eql(u8, tool_name, "run_command")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const command = getStringArg(args, "command") orelse return error.MissingCommand;
        const wait_for = getStringArg(args, "wait_for");
        const timeout_ms = getIntArg(args, "timeout_ms") orelse 30_000;

        try zmx.ensureSessionExists(ctx.alloc, ctx.cfg, name);

        // Snapshot history length before the command so we only match against new output.
        var history_offset: usize = 0;
        if (wait_for != null) {
            const pre = try zmx.readHistory(ctx.cfg, ctx.alloc, name, .plain);
            history_offset = pre.len;
            ctx.alloc.free(pre);
        }

        try zmx.runCommand(ctx.alloc, ctx.cfg, name, command);

        if (wait_for) |pattern| {
            const deadline = std.time.milliTimestamp() + timeout_ms;
            while (true) {
                const history = try zmx.readHistory(ctx.cfg, ctx.alloc, name, .plain);
                defer ctx.alloc.free(history);

                // Clamp offset defensively in case the buffer shrank.
                const offset = @min(history_offset, history.len);
                const new_output = history[offset..];

                if (std.mem.indexOf(u8, new_output, pattern) != null) {
                    return toolTextResult(ctx.alloc, new_output);
                }

                if (std.time.milliTimestamp() >= deadline) {
                    const msg = try std.fmt.allocPrint(
                        ctx.alloc,
                        "Timeout after {d}ms waiting for '{s}' in session '{s}'.",
                        .{ timeout_ms, pattern, name },
                    );
                    defer ctx.alloc.free(msg);
                    return toolTextResult(ctx.alloc, msg);
                }

                std.Thread.sleep(200 * std.time.ns_per_ms);
            }
        }

        const msg = try std.fmt.allocPrint(ctx.alloc, "Sent command to '{s}': {s}", .{ name, command });
        defer ctx.alloc.free(msg);
        return toolTextResult(ctx.alloc, msg);
    }

    if (std.mem.eql(u8, tool_name, "wait_session")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        const timeout_ms = getIntArg(args, "timeout_ms") orelse 30_000;

        const deadline = std.time.milliTimestamp() + timeout_ms;

        while (true) {
            const info = try zmx.readInfo(ctx.cfg, ctx.alloc, name);
            if (info.task_ended_at != 0) {
                const cmd_len: usize = @intCast(@min(info.cmd_len, zmx.MAX_CMD_LEN));
                const cmd = info.cmd[0..cmd_len];
                const done_msg = try std.fmt.allocPrint(
                    ctx.alloc,
                    "Session '{s}' task completed. exit_code={d} task_ended_at={d} command={s}",
                    .{ name, info.task_exit_code, info.task_ended_at, cmd },
                );
                defer ctx.alloc.free(done_msg);
                return toolTextResult(ctx.alloc, done_msg);
            }

            if (std.time.milliTimestamp() >= deadline) {
                const timeout_msg = try std.fmt.allocPrint(ctx.alloc, "Timeout waiting for session '{s}'.", .{name});
                defer ctx.alloc.free(timeout_msg);
                return toolTextResult(ctx.alloc, timeout_msg);
            }

            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    }

    if (std.mem.eql(u8, tool_name, "list_sessions")) {
        const sessions = try zmx.listSessions(ctx.cfg, ctx.alloc);
        defer zmx.deinitSessionInfos(ctx.alloc, sessions);

        if (sessions.len == 0) {
            return toolTextResult(ctx.alloc, "No active sessions found.");
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(ctx.alloc);

        for (sessions) |session| {
            const line = try std.fmt.allocPrint(
                ctx.alloc,
                "name={s}\tpid={d}\tclients={d}\ttask_exit_code={d}\ttask_ended_at={d}\tcwd={s}\tcmd={s}\n",
                .{ session.name, session.pid, session.clients, session.task_exit_code, session.task_ended_at, session.cwd, session.cmd },
            );
            try out.appendSlice(ctx.alloc, line);
            ctx.alloc.free(line);
        }

        return toolTextResult(ctx.alloc, out.items);
    }

    if (std.mem.eql(u8, tool_name, "kill_session") or std.mem.eql(u8, tool_name, "close_session")) {
        const name = getStringArg(args, "name") orelse return error.MissingSessionName;
        try zmx.killSession(ctx.cfg, ctx.alloc, name);

        const msg = try std.fmt.allocPrint(ctx.alloc, "Killed session '{s}'.", .{name});
        defer ctx.alloc.free(msg);
        return toolTextResult(ctx.alloc, msg);
    }

    return error.UnknownTool;
}

fn keyToInputBytes(alloc: std.mem.Allocator, key: []const u8, modifiers: ?[]const u8) ![]u8 {
    const mods = modifiers orelse "";
    const has_control = hasModifier(mods, "control");
    const has_shift = hasModifier(mods, "shift");
    const has_option = hasModifier(mods, "option");
    const has_command = hasModifier(mods, "command");

    if (has_option or has_command) {
        return error.UnsupportedModifier;
    }

    if (std.ascii.eqlIgnoreCase(key, "enter")) return alloc.dupe(u8, "\r");
    if (std.ascii.eqlIgnoreCase(key, "tab")) return alloc.dupe(u8, "\t");
    if (std.ascii.eqlIgnoreCase(key, "escape")) return alloc.dupe(u8, "\x1b");
    if (std.ascii.eqlIgnoreCase(key, "up")) return alloc.dupe(u8, "\x1b[A");
    if (std.ascii.eqlIgnoreCase(key, "down")) return alloc.dupe(u8, "\x1b[B");
    if (std.ascii.eqlIgnoreCase(key, "right")) return alloc.dupe(u8, "\x1b[C");
    if (std.ascii.eqlIgnoreCase(key, "left")) return alloc.dupe(u8, "\x1b[D");
    if (std.ascii.eqlIgnoreCase(key, "backspace")) return alloc.dupe(u8, "\x7f");
    if (std.ascii.eqlIgnoreCase(key, "delete")) return alloc.dupe(u8, "\x1b[3~");
    if (std.ascii.eqlIgnoreCase(key, "space")) return alloc.dupe(u8, " ");

    if (key.len == 1) {
        var byte = key[0];
        if (has_shift and std.ascii.isAlphabetic(byte)) {
            byte = std.ascii.toUpper(byte);
        }

        if (has_control) {
            if (!std.ascii.isAlphabetic(byte)) {
                return error.UnsupportedControlKey;
            }
            byte = std.ascii.toUpper(byte) & 0x1f;
        }

        var out = try alloc.alloc(u8, 1);
        out[0] = byte;
        return out;
    }

    return error.UnsupportedKey;
}

fn hasModifier(modifiers: []const u8, needle: []const u8) bool {
    var iter = std.mem.splitScalar(u8, modifiers, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (std.ascii.eqlIgnoreCase(trimmed, needle)) {
            return true;
        }
    }
    return false;
}

fn popFramedMessage(alloc: std.mem.Allocator, inbound: *std.ArrayList(u8)) !?InboundFrame {
    while (true) {
        if (inbound.items.len == 0) {
            return null;
        }

        if (startsWithContentLengthHeader(inbound.items)) {
            return try popContentLengthFramedMessage(alloc, inbound);
        }

        const newline_index = std.mem.indexOfScalar(u8, inbound.items, '\n') orelse return null;
        var line_end = newline_index;
        if (line_end > 0 and inbound.items[line_end - 1] == '\r') {
            line_end -= 1;
        }

        const line = inbound.items[0..line_end];
        const consumed = newline_index + 1;

        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            consumeInbound(inbound, consumed);
            continue;
        }

        const body = try alloc.dupe(u8, line);
        consumeInbound(inbound, consumed);
        return .{ .body = body, .framing = .newline };
    }
}

fn popContentLengthFramedMessage(alloc: std.mem.Allocator, inbound: *std.ArrayList(u8)) !?InboundFrame {
    const header_terminator = findHeaderTerminator(inbound.items) orelse return null;
    const headers = inbound.items[0..header_terminator.index];
    const content_length = parseContentLength(headers) orelse return error.MissingContentLength;
    const body_start = header_terminator.index + header_terminator.delim_len;
    const total_len = body_start + content_length;

    if (inbound.items.len < total_len) {
        return null;
    }

    const body = try alloc.dupe(u8, inbound.items[body_start..total_len]);
    consumeInbound(inbound, total_len);

    return .{ .body = body, .framing = .content_length };
}

const HeaderTerminator = struct {
    index: usize,
    delim_len: usize,
};

fn findHeaderTerminator(bytes: []const u8) ?HeaderTerminator {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| {
        return .{ .index = index, .delim_len = 4 };
    }
    if (std.mem.indexOf(u8, bytes, "\n\n")) |index| {
        return .{ .index = index, .delim_len = 2 };
    }
    return null;
}

fn startsWithContentLengthHeader(bytes: []const u8) bool {
    const line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    var line = bytes[0..line_end];
    line = std.mem.trimRight(u8, line, "\r");

    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    return std.ascii.eqlIgnoreCase(key, "Content-Length");
}

fn consumeInbound(inbound: *std.ArrayList(u8), consumed: usize) void {
    const remaining = inbound.items.len - consumed;
    if (remaining > 0) {
        std.mem.copyForwards(u8, inbound.items[0..remaining], inbound.items[consumed..]);
    }
    inbound.items.len = remaining;
}

fn parseContentLength(headers: []const u8) ?usize {
    const line_delim = if (std.mem.indexOf(u8, headers, "\r\n") != null) "\r\n" else "\n";
    var lines = std.mem.splitSequence(u8, headers, line_delim);
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "Content-Length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn writeMcpFrame(fd: i32, alloc: std.mem.Allocator, body: []const u8, framing: MessageFraming) !void {
    switch (framing) {
        .content_length => {
            const header = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n", .{body.len});
            defer alloc.free(header);

            try writeAll(fd, header);
            try writeAll(fd, body);
        },
        .newline => {
            try writeAll(fd, body);
            try writeAll(fd, "\n");
        },
    }
}

fn negotiateProtocolVersion(request_obj: std.json.ObjectMap) []const u8 {
    const params = request_obj.get("params") orelse return MCP_PROTOCOL_VERSION_LATEST;
    if (params != .object) return MCP_PROTOCOL_VERSION_LATEST;

    const requested = getStringFromObject(params.object, "protocolVersion") orelse return MCP_PROTOCOL_VERSION_LATEST;
    if (std.mem.eql(u8, requested, MCP_PROTOCOL_VERSION_LATEST)) return requested;
    if (std.mem.eql(u8, requested, MCP_PROTOCOL_VERSION_INTERMEDIATE)) return requested;
    if (std.mem.eql(u8, requested, MCP_PROTOCOL_VERSION_LEGACY)) return requested;

    // For unknown versions, return the newest version we support that is not newer than requested.
    // This keeps initialization interoperable with clients that understand multiple versions.
    for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.order(u8, requested, supported) != .lt) {
            return supported;
        }
    }

    return MCP_PROTOCOL_VERSION_LEGACY;
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

fn getStringFromObject(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getStringArg(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (args == null) return null;
    return getStringFromObject(args.?, key);
}

fn getIntFromObject(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn getIntArg(args: ?std.json.ObjectMap, key: []const u8) ?i64 {
    if (args == null) return null;
    return getIntFromObject(args.?, key);
}

fn idValueToJson(alloc: std.mem.Allocator, id_value: ?std.json.Value) ![]u8 {
    if (id_value == null) {
        return alloc.dupe(u8, "null");
    }

    const id = id_value.?;
    return switch (id) {
        .null => alloc.dupe(u8, "null"),
        .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .float => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .string => |s| quoteJsonString(alloc, s),
        else => alloc.dupe(u8, "null"),
    };
}

fn buildSuccessResponse(alloc: std.mem.Allocator, id_json: []const u8, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn buildErrorResponse(alloc: std.mem.Allocator, id_json: []const u8, rpc_error: RpcError) ![]u8 {
    const msg = try quoteJsonString(alloc, rpc_error.message);
    defer alloc.free(msg);

    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json, rpc_error.code, msg },
    );
}

fn toolTextResult(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try quoteJsonString(alloc, text);
    defer alloc.free(escaped);

    return std.fmt.allocPrint(
        alloc,
        "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}]}}",
        .{escaped},
    );
}

fn quoteJsonString(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try out.append(alloc, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0C => try out.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(alloc, "\\u00");
                    try out.append(alloc, hexDigit(c >> 4));
                    try out.append(alloc, hexDigit(c & 0x0f));
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');

    return out.toOwnedSlice(alloc);
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

fn buildToolsListResult(alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"tools\":[");
    for (TOOLS, 0..) |tool, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeToolDef(alloc, &out, tool);
    }
    try out.appendSlice(alloc, "]}");

    return out.toOwnedSlice(alloc);
}

fn writeToolDef(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tool: ToolDef) !void {
    const name_json = try quoteJsonString(alloc, tool.name);
    defer alloc.free(name_json);
    const desc_json = try quoteJsonString(alloc, tool.description);
    defer alloc.free(desc_json);

    try out.appendSlice(alloc, "{\"name\":");
    try out.appendSlice(alloc, name_json);
    try out.appendSlice(alloc, ",\"description\":");
    try out.appendSlice(alloc, desc_json);
    try out.appendSlice(alloc, ",\"inputSchema\":{\"type\":\"object\",\"properties\":{");

    for (tool.params, 0..) |param, i| {
        if (i > 0) try out.append(alloc, ',');

        const pname_json = try quoteJsonString(alloc, param.name);
        defer alloc.free(pname_json);
        const ptype_json = try quoteJsonString(alloc, param.type_name);
        defer alloc.free(ptype_json);

        try out.appendSlice(alloc, pname_json);
        try out.appendSlice(alloc, ":{\"type\":");
        try out.appendSlice(alloc, ptype_json);
        if (param.description) |desc| {
            const pdesc_json = try quoteJsonString(alloc, desc);
            defer alloc.free(pdesc_json);
            try out.appendSlice(alloc, ",\"description\":");
            try out.appendSlice(alloc, pdesc_json);
        }
        try out.append(alloc, '}');
    }

    try out.append(alloc, '}');

    var first_required = true;
    for (tool.params) |param| {
        if (!param.required) continue;
        if (first_required) {
            try out.appendSlice(alloc, ",\"required\":[");
            first_required = false;
        } else {
            try out.append(alloc, ',');
        }
        const req_json = try quoteJsonString(alloc, param.name);
        defer alloc.free(req_json);
        try out.appendSlice(alloc, req_json);
    }
    if (!first_required) try out.append(alloc, ']');

    try out.appendSlice(alloc, "}}");
}

test "content length parser" {
    const headers = "Content-Length: 42\r\nFoo: bar";
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength(headers));
}

test "pop newline framed message" {
    const alloc = std.testing.allocator;
    var inbound = try std.ArrayList(u8).initCapacity(alloc, 64);
    defer inbound.deinit(alloc);

    try inbound.appendSlice(alloc, "{\"jsonrpc\":\"2.0\"}\n");

    const maybe_frame = try popFramedMessage(alloc, &inbound);
    try std.testing.expect(maybe_frame != null);
    const frame = maybe_frame.?;
    defer alloc.free(frame.body);

    try std.testing.expectEqual(MessageFraming.newline, frame.framing);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", frame.body);
    try std.testing.expectEqual(@as(usize, 0), inbound.items.len);
}

test "pop content-length framed message" {
    const alloc = std.testing.allocator;
    var inbound = try std.ArrayList(u8).initCapacity(alloc, 128);
    defer inbound.deinit(alloc);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const framed = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer alloc.free(framed);
    try inbound.appendSlice(alloc, framed);

    const maybe_frame = try popFramedMessage(alloc, &inbound);
    try std.testing.expect(maybe_frame != null);
    const frame = maybe_frame.?;
    defer alloc.free(frame.body);

    try std.testing.expectEqual(MessageFraming.content_length, frame.framing);
    try std.testing.expectEqualStrings(body, frame.body);
    try std.testing.expectEqual(@as(usize, 0), inbound.items.len);
}

test "buildToolsListResult produces single-line JSON with all tools" {
    const alloc = std.testing.allocator;
    const result = try buildToolsListResult(alloc);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '\r') == null);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"tools\":["));
    try std.testing.expect(std.mem.endsWith(u8, result, "]}"));
    for (TOOLS) |tool| {
        try std.testing.expect(std.mem.indexOf(u8, result, tool.name) != null);
    }
}

test "tools/list response is single-line jsonrpc" {
    const alloc = std.testing.allocator;
    const cfg = zmx.Config{ .socket_dir = "" };
    const tools_list = try buildToolsListResult(alloc);
    defer alloc.free(tools_list);
    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";

    const maybe_response = try handleMessage(alloc, cfg, tools_list, request);
    try std.testing.expect(maybe_response != null);
    const response = maybe_response.?;
    defer alloc.free(response);

    try std.testing.expect(std.mem.indexOfScalar(u8, response, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, response, '\r') == null);
}

test "json string quoting" {
    const alloc = std.testing.allocator;
    const quoted = try quoteJsonString(alloc, "line\n\"quoted\"");
    defer alloc.free(quoted);
    try std.testing.expectEqualStrings("\"line\\n\\\"quoted\\\"\"", quoted);
}

test "protocol negotiation supports 2025-03-26" {
    const alloc = std.testing.allocator;
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(MCP_PROTOCOL_VERSION_INTERMEDIATE, negotiateProtocolVersion(parsed.value.object));
}

test "protocol negotiation falls back for unknown future version" {
    const alloc = std.testing.allocator;
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-12-31","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(MCP_PROTOCOL_VERSION_LATEST, negotiateProtocolVersion(parsed.value.object));
}
