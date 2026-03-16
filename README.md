# ghostty-mcp

An MCP server that provides terminal session management via [zmx](https://github.com/ghostty-org/zmx) IPC over Unix domain sockets.

- Deterministic, headless session control (no GUI dependency)
- Reliable session history from `libghostty-vt`
- Process/task lifecycle and exit code visibility
- macOS + Linux portability

## MCP subset

Implements a minimal MCP/JSON-RPC 2.0 subset over stdio:

- `initialize`
- `notifications/initialized` (and legacy `initialized`)
- `tools/list`
- `tools/call`

No MCP resources, prompts, or sampling are included.

## Tools

- `create_session` — Create a zmx session by name with an optional initial command
- `input_text` — Send raw text bytes into a session
- `send_key` — Send a keypress (named keys or single character with optional modifiers)
- `read_output` — Read terminal history (plain, vt, or html format)
- `run_command` — Execute a shell command and wait for daemon Ack
- `wait_session` — Poll session task state until completion or timeout
- `list_sessions` — List discoverable zmx sessions
- `kill_session` — Kill a session process and detach clients
- `close_session` — Alias for `kill_session`

## Build and run

Requires Zig `0.15` and `zmx` on `PATH`.

```bash
zig build
zig build run
```

The server communicates via newline-delimited MCP stdio framing and accepts legacy `Content-Length` framing for compatibility.

Protocol negotiation currently supports `2025-06-18`, `2025-03-26`, and `2024-11-05`.

## Notes

- Session bootstrap uses `zmx run <name> true` when a named session does not yet exist.
- Runtime socket directory follows zmx resolution order:
  - `ZMX_DIR`
  - `XDG_RUNTIME_DIR/zmx`
  - `TMPDIR/zmx-{uid}`
  - `/tmp/zmx-{uid}`
