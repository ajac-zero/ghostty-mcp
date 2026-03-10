"""Ghostty MCP server — manage terminal sessions via AppleScript."""

from ghostty_mcp.server import mcp


def main() -> None:
    """Run the MCP server."""
    mcp.run()
