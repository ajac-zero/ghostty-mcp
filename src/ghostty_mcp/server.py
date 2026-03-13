"""MCP server exposing Ghostty terminal management tools."""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from ghostty_mcp.session import SessionManager

mcp = FastMCP(
    "ghostty-mcp",
    instructions=(
        "MCP server for managing Ghostty terminal sessions. "
        "Use create_session to start terminals, input_text to paste text, "
        "send_key to send keyboard inputs (enter, ctrl+c, etc.), "
        "and read_output to see results."
    ),
)
manager = SessionManager()


@mcp.tool()
def create_session(  # noqa: PLR0913
    surface_type: str = "tab",
    command: str | None = None,
    working_directory: str | None = None,
    environment: dict[str, str] | None = None,
    split_direction: str = "right",
    split_target: str | None = None,
) -> dict[str, str | None]:
    """Create a new Ghostty terminal session.

    Args:
        surface_type: One of "tab", "window", or "split".
        command: Optional shell command to run in the session.
        working_directory: Starting directory for the session.
        environment: Additional environment variables as key-value pairs.
        split_direction: Split direction when surface_type is "split".
            One of "right", "left", "up", "down".
        split_target: Terminal ID to split from when surface_type is "split".
            If not provided, splits the currently focused terminal.

    Returns:
        Session info with terminal_id, name, working_directory, and command.

    """
    session = manager.create_session(
        surface_type=surface_type,
        command=command,
        working_directory=working_directory,
        environment=environment,
        split_direction=split_direction,
        split_target=split_target,
    )
    return {
        "terminal_id": session.terminal_id,
        "name": session.name,
        "working_directory": session.working_directory,
        "command": session.command,
    }


@mcp.tool()
def input_text(terminal_id: str, text: str) -> str:
    r"""Send text to a terminal session (paste-style).

    This tool pastes text into the terminal WITHOUT pressing Enter. It's like using
    the clipboard to paste—the text appears in the terminal but is not executed.

    To submit a command, you must separately call send_key with 'enter' after using
    this tool.

    Args:
        terminal_id: The session's terminal ID.
        text: Text to send.

    Returns:
        Confirmation message.

    Example:
        input_text(terminal_id, "python3 script.py")
        send_key(terminal_id, 'enter')

    """
    manager.input_text(terminal_id, text)
    return f"Sent input to {terminal_id}."


@mcp.tool()
def send_key(terminal_id: str, key: str, modifiers: str | None = None) -> str:
    """Send a key press event to a terminal session.

    Args:
        terminal_id: The session's terminal ID.
        key: Named key or single letter. Named keys: enter, tab, escape, up,
            down, left, right, backspace, delete, space. Use a single letter
            (e.g. "c") combined with modifiers for shortcuts like ctrl+c.
        modifiers: Optional comma-separated modifier string. Accepted values:
            control, shift, option, command.

    Returns:
        Confirmation message.

    Example:
        send_key(terminal_id, 'enter')
        send_key(terminal_id, 'c', modifiers='control')

    """
    manager.send_key(terminal_id, key, modifiers)
    return f"Sent key '{key}' to {terminal_id}."


@mcp.tool()
def read_output(terminal_id: str) -> str:
    """Read the current screen contents of a terminal session.

    Args:
        terminal_id: The session's terminal ID.

    Returns:
        The text currently visible on the terminal screen.

    """
    return manager.read_output(terminal_id)


@mcp.tool()
def list_sessions() -> list[dict[str, str | None]]:
    """List all tracked terminal sessions.

    Only sessions created via create_session or added via add_session are
    tracked. Dead sessions are automatically pruned.

    Returns:
        A list of session info dicts.

    """
    return [
        {
            "terminal_id": s.terminal_id,
            "name": s.name,
            "working_directory": s.working_directory,
            "command": s.command,
        }
        for s in manager.list_sessions()
    ]


@mcp.tool()
def close_session(terminal_id: str) -> str:
    """Close a terminal session and remove it from tracking.

    Args:
        terminal_id: The session's terminal ID.

    Returns:
        Confirmation message.

    """
    manager.close_session(terminal_id)
    return f"Closed session {terminal_id}."


# TODO(future): Add an `add_session` tool to let users adopt  # noqa: FIX002, TD003
# pre-existing terminals once Ghostty's AppleScript API supports user-set
# tab titles or provides another discoverable identifier.
