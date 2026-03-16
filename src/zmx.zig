const std = @import("std");
const posix = std.posix;

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    _,
};

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = packed struct {
    rows: u16,
    cols: u16,
};

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

pub const Info = extern struct {
    clients_len: usize,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub const HistoryFormat = enum(u8) {
    plain = 0,
    vt = 1,
    html = 2,
};

pub const SessionInfo = struct {
    name: []u8,
    pid: i32,
    clients: usize,
    cmd: []u8,
    cwd: []u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub fn deinitSessionInfos(alloc: std.mem.Allocator, infos: []SessionInfo) void {
    for (infos) |info| {
        alloc.free(info.name);
        alloc.free(info.cmd);
        alloc.free(info.cwd);
    }
    alloc.free(infos);
}

pub const Config = struct {
    socket_dir: []u8,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.socket_dir);
    }
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        const total = expectedLength(available) orelse return null;
        if (available.len < total) return null;

        const hdr = std.mem.bytesToValue(Header, available[0..@sizeOf(Header)]);
        const payload = available[@sizeOf(Header)..total];
        self.head += total;

        return .{ .header = hdr, .payload = payload };
    }
};

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub fn resolveConfig(alloc: std.mem.Allocator) !Config {
    const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
    const uid = posix.getuid();

    const socket_dir = if (posix.getenv("ZMX_DIR")) |zmx_dir|
        try alloc.dupe(u8, zmx_dir)
    else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
        try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
    else
        try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });

    return .{ .socket_dir = socket_dir };
}

pub fn getSocketPath(alloc: std.mem.Allocator, cfg: Config, session_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ cfg.socket_dir, session_name });
}

pub fn sessionConnect(socket_path: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &unix_addr.any, unix_addr.getOsSockLen());
    return fd;
}

pub fn sessionExists(cfg: Config, alloc: std.mem.Allocator, session_name: []const u8) bool {
    const socket_path = getSocketPath(alloc, cfg, session_name) catch return false;
    defer alloc.free(socket_path);

    const fd = sessionConnect(socket_path) catch return false;
    posix.close(fd);
    return true;
}

pub fn ensureSessionExists(alloc: std.mem.Allocator, cfg: Config, session_name: []const u8) !void {
    if (sessionExists(cfg, alloc, session_name)) {
        return;
    }

    try bootstrapSession(alloc, session_name);

    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const deadline_ms = std.time.milliTimestamp() + 2_000;
    while (std.time.milliTimestamp() < deadline_ms) {
        const fd = sessionConnect(socket_path) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        posix.close(fd);
        return;
    }

    return error.SessionBootstrapTimeout;
}

pub fn bootstrapSession(alloc: std.mem.Allocator, session_name: []const u8) !void {
    if (!isValidSessionName(session_name)) {
        return error.InvalidSessionName;
    }

    const argv: []const []const u8 = &.{ "zmx", "run", session_name, "true" };
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return error.SessionBootstrapFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.SessionBootstrapFailed,
        else => return error.SessionBootstrapFailed,
    }
}

pub fn runCommand(alloc: std.mem.Allocator, cfg: Config, session_name: []const u8, command: []const u8) !void {
    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const fd = try sessionConnect(socket_path);
    defer posix.close(fd);

    const payload = try buildRunPayload(alloc, command);
    defer alloc.free(payload);

    try send(fd, .Run, payload);
    const ack = try waitForTagPayload(alloc, fd, .Ack, 5_000);
    defer alloc.free(ack);
}

pub fn sendInput(cfg: Config, alloc: std.mem.Allocator, session_name: []const u8, bytes: []const u8) !void {
    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const fd = try sessionConnect(socket_path);
    defer posix.close(fd);

    try send(fd, .Input, bytes);
}

pub fn killSession(cfg: Config, alloc: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const fd = try sessionConnect(socket_path);
    defer posix.close(fd);

    try send(fd, .Kill, "");
}

pub fn readInfo(cfg: Config, alloc: std.mem.Allocator, session_name: []const u8) !Info {
    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const fd = try sessionConnect(socket_path);
    defer posix.close(fd);

    try send(fd, .Info, "");
    const payload = try waitForTagPayload(alloc, fd, .Info, 1_000);
    defer alloc.free(payload);

    if (payload.len != @sizeOf(Info)) {
        return error.InvalidInfoPayload;
    }

    return std.mem.bytesToValue(Info, payload[0..@sizeOf(Info)]);
}

pub fn readHistory(cfg: Config, alloc: std.mem.Allocator, session_name: []const u8, format: HistoryFormat) ![]u8 {
    const socket_path = try getSocketPath(alloc, cfg, session_name);
    defer alloc.free(socket_path);

    const fd = try sessionConnect(socket_path);
    defer posix.close(fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    try send(fd, .History, &format_byte);
    return waitForTagPayload(alloc, fd, .History, 1_000);
}

pub fn listSessions(cfg: Config, alloc: std.mem.Allocator) ![]SessionInfo {
    var dir = std.fs.openDirAbsolute(cfg.socket_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc(SessionInfo, 0),
        else => return err,
    };
    defer dir.close();

    var infos = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (infos.items) |session| {
            alloc.free(session.name);
            alloc.free(session.cmd);
            alloc.free(session.cwd);
        }
        infos.deinit(alloc);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .unix_domain_socket) continue;
        if (std.mem.eql(u8, entry.name, "logs")) continue;

        const session_name = entry.name;
        const info = readInfo(cfg, alloc, session_name) catch continue;
        const cmd_len: usize = @intCast(@min(info.cmd_len, MAX_CMD_LEN));
        const cwd_len: usize = @intCast(@min(info.cwd_len, MAX_CWD_LEN));

        try infos.append(alloc, .{
            .name = try alloc.dupe(u8, session_name),
            .pid = info.pid,
            .clients = info.clients_len,
            .cmd = try alloc.dupe(u8, info.cmd[0..cmd_len]),
            .cwd = try alloc.dupe(u8, info.cwd[0..cwd_len]),
            .created_at = info.created_at,
            .task_ended_at = info.task_ended_at,
            .task_exit_code = info.task_exit_code,
        });
    }

    return infos.toOwnedSlice(alloc);
}

pub fn historyFormatFromString(value: []const u8) HistoryFormat {
    if (std.ascii.eqlIgnoreCase(value, "vt")) return .vt;
    if (std.ascii.eqlIgnoreCase(value, "html")) return .html;
    return .plain;
}

pub fn buildRunPayload(alloc: std.mem.Allocator, command: []const u8) ![]u8 {
    const shell = posix.getenv("SHELL") orelse "/bin/sh";
    const shell_basename = std.fs.path.basename(shell);

    const marker = if (std.mem.eql(u8, shell_basename, "fish"))
        "; echo ZMX_TASK_COMPLETED:$status"
    else
        "; echo ZMX_TASK_COMPLETED:$?";

    return std.fmt.allocPrint(alloc, "{s}{s}\r", .{ command, marker });
}

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    return @as(usize, @sizeOf(Header)) + @as(usize, header.len);
}

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    const header = Header{ .tag = tag, .len = @intCast(data.len) };
    try writeAll(fd, std.mem.asBytes(&header));
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

fn waitForTagPayload(alloc: std.mem.Allocator, fd: i32, wanted: Tag, timeout_ms: i32) ![]u8 {
    var socket_buf = try SocketBuffer.init(alloc);
    defer socket_buf.deinit();

    var poll_fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    while (true) {
        const poll_res = try posix.poll(&poll_fds, timeout_ms);
        if (poll_res == 0) return error.Timeout;

        const bytes_read = try socket_buf.read(fd);
        if (bytes_read == 0) return error.ConnectionClosed;

        while (socket_buf.next()) |msg| {
            if (msg.header.tag == wanted) {
                return alloc.dupe(u8, msg.payload);
            }
        }
    }
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

fn isValidSessionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const is_allowed = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!is_allowed) return false;
    }
    return true;
}

test "history format parsing" {
    try std.testing.expectEqual(HistoryFormat.plain, historyFormatFromString("plain"));
    try std.testing.expectEqual(HistoryFormat.vt, historyFormatFromString("vt"));
    try std.testing.expectEqual(HistoryFormat.html, historyFormatFromString("html"));
}

test "run payload includes completion marker" {
    const alloc = std.testing.allocator;
    const payload = try buildRunPayload(alloc, "echo hi");
    defer alloc.free(payload);

    try std.testing.expect(std.mem.endsWith(u8, payload, "\r"));
    try std.testing.expect(std.mem.indexOf(u8, payload, "ZMX_TASK_COMPLETED:") != null);
}

test "isValidSessionName accepts alphanumeric and separators" {
    try std.testing.expect(isValidSessionName("my-session"));
    try std.testing.expect(isValidSessionName("test_01"));
    try std.testing.expect(isValidSessionName("a.b.c"));
    try std.testing.expect(isValidSessionName("X"));
}

test "isValidSessionName rejects empty and special chars" {
    try std.testing.expect(!isValidSessionName(""));
    try std.testing.expect(!isValidSessionName("bad name"));
    try std.testing.expect(!isValidSessionName("no/slash"));
    try std.testing.expect(!isValidSessionName("a@b"));
}

test "expectedLength returns null for short data" {
    try std.testing.expectEqual(@as(?usize, null), expectedLength(""));
    try std.testing.expectEqual(@as(?usize, null), expectedLength("abc"));
}

test "expectedLength parses header correctly" {
    const header = Header{ .tag = .Input, .len = 10 };
    const bytes = std.mem.asBytes(&header);
    try std.testing.expectEqual(@as(?usize, @sizeOf(Header) + 10), expectedLength(bytes));
}

test "SocketBuffer.next parses single message" {
    const alloc = std.testing.allocator;
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();

    const payload = "hello";
    const header = Header{ .tag = .Output, .len = @intCast(payload.len) };
    try sb.buf.appendSlice(alloc, std.mem.asBytes(&header));
    try sb.buf.appendSlice(alloc, payload);

    const msg = sb.next();
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(Tag.Output, msg.?.header.tag);
    try std.testing.expectEqualStrings("hello", msg.?.payload);

    // No more messages
    try std.testing.expect(sb.next() == null);
}

test "SocketBuffer.next handles multiple messages" {
    const alloc = std.testing.allocator;
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();

    // Write two messages back-to-back
    const p1 = "abc";
    const h1 = Header{ .tag = .Input, .len = @intCast(p1.len) };
    try sb.buf.appendSlice(alloc, std.mem.asBytes(&h1));
    try sb.buf.appendSlice(alloc, p1);

    const p2 = "defgh";
    const h2 = Header{ .tag = .Ack, .len = @intCast(p2.len) };
    try sb.buf.appendSlice(alloc, std.mem.asBytes(&h2));
    try sb.buf.appendSlice(alloc, p2);

    const msg1 = sb.next();
    try std.testing.expect(msg1 != null);
    try std.testing.expectEqual(Tag.Input, msg1.?.header.tag);
    try std.testing.expectEqualStrings("abc", msg1.?.payload);

    const msg2 = sb.next();
    try std.testing.expect(msg2 != null);
    try std.testing.expectEqual(Tag.Ack, msg2.?.header.tag);
    try std.testing.expectEqualStrings("defgh", msg2.?.payload);

    try std.testing.expect(sb.next() == null);
}

test "SocketBuffer.next returns null for incomplete message" {
    const alloc = std.testing.allocator;
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();

    // Header says 10 bytes payload but only provide 3
    const header = Header{ .tag = .Output, .len = 10 };
    try sb.buf.appendSlice(alloc, std.mem.asBytes(&header));
    try sb.buf.appendSlice(alloc, "abc");

    try std.testing.expect(sb.next() == null);
}

test "SocketBuffer.next handles zero-length payload" {
    const alloc = std.testing.allocator;
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();

    const header = Header{ .tag = .Kill, .len = 0 };
    try sb.buf.appendSlice(alloc, std.mem.asBytes(&header));

    const msg = sb.next();
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(Tag.Kill, msg.?.header.tag);
    try std.testing.expectEqual(@as(usize, 0), msg.?.payload.len);
}

test "send writes header and payload to pipe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const payload = "test data";
    try send(fds[1], .Run, payload);

    var read_buf: [@sizeOf(Header) + payload.len]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = try posix.read(fds[0], read_buf[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expectEqual(read_buf.len, total);

    const hdr = std.mem.bytesToValue(Header, read_buf[0..@sizeOf(Header)]);
    try std.testing.expectEqual(Tag.Run, hdr.tag);
    try std.testing.expectEqual(@as(u32, payload.len), hdr.len);
    try std.testing.expectEqualStrings(payload, read_buf[@sizeOf(Header)..]);
}

test "send writes header only for empty payload" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try send(fds[1], .Kill, "");

    var read_buf: [@sizeOf(Header)]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = try posix.read(fds[0], read_buf[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expectEqual(@sizeOf(Header), total);

    const hdr = std.mem.bytesToValue(Header, read_buf[0..@sizeOf(Header)]);
    try std.testing.expectEqual(Tag.Kill, hdr.tag);
    try std.testing.expectEqual(@as(u32, 0), hdr.len);
}

test "getSocketPath builds correct path" {
    const alloc = std.testing.allocator;
    const cfg = Config{ .socket_dir = @constCast("/tmp/zmx-501") };
    const path = try getSocketPath(alloc, cfg, "my-session");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/zmx-501/my-session", path);
}
