"""MCP server exposing Ghostty terminal management tools."""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from ghostty_mcp.session import SessionManager

mcp = FastMCP(
    "ghostty-mcp",
    instructions=(
        "MCP server for managing Ghostty terminal sessions. "
        "You can create sessions, send input, read output, and list sessions."
    ),
)
manager = SessionManager()


@mcp.tool()
def create_session(
    surface_type: str = "tab",
    command: str | None = None,
    working_directory: str | None = None,
    environment: dict[str, str] | None = None,
    split_direction: str = "right",
) -> dict[str, str | None]:
    """Create a new Ghostty terminal session.

    Args:
        surface_type: One of "tab", "window", or "split".
        command: Optional shell command to run in the session.
        working_directory: Starting directory for the session.
        environment: Additional environment variables as key-value pairs.
        split_direction: Split direction when surface_type is "split".
            One of "right", "left", "up", "down".

    Returns:
        Session info with terminal_id, name, working_directory, and command.

    """
    session = manager.create_session(
        surface_type=surface_type,
        command=command,
        working_directory=working_directory,
        environment=environment,
        split_direction=split_direction,
    )
    return {
        "terminal_id": session.terminal_id,
        "name": session.name,
        "working_directory": session.working_directory,
        "command": session.command,
    }


@mcp.tool()
def send_input(terminal_id: str, text: str) -> str:
    r"""Send text input to a terminal session.

    Args:
        terminal_id: The session's terminal ID.
        text: Text to send. Include "<>enter<>" to simulate pressing Enter.

    Returns:
        Confirmation message.

    """
    manager.send_input(terminal_id, text)
    return f"Sent input to {terminal_id}."


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

    Dead sessions are automatically pruned. On a fresh server start,
    this will also discover existing Ghostty terminals.

    Returns:
        A list of session info dicts.

    """
    sessions = manager.list_sessions()
    if not sessions:
        sessions = manager.discover_sessions()
    return [
        {
            "terminal_id": s.terminal_id,
            "name": s.name,
            "working_directory": s.working_directory,
            "command": s.command,
        }
        for s in sessions
    ]
