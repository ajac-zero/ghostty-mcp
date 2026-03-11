"""Session manager: tracks terminal sessions and delegates to GhosttyBridge."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import TYPE_CHECKING

from ghostty_mcp.bridge import GhosttyBridge, SurfaceConfig

if TYPE_CHECKING:
    from ghostty_mcp.bridge import TerminalInfo


@dataclass
class Session:
    """In-memory record of a tracked session."""

    terminal_id: str
    name: str
    working_directory: str
    command: str | None = None


class SessionManager:
    """Track terminal sessions and delegate to GhosttyBridge."""

    def __init__(self, bridge: GhosttyBridge | None = None) -> None:
        """Initialize with an optional bridge instance."""
        self._bridge = bridge or GhosttyBridge()
        self._sessions: dict[str, Session] = {}

    # ------------------------------------------------------------------
    # Session lifecycle
    # ------------------------------------------------------------------

    def create_session(
        self,
        *,
        surface_type: str = "tab",
        command: str | None = None,
        working_directory: str | None = None,
        environment: dict[str, str] | None = None,
        split_direction: str = "right",
    ) -> Session:
        """Create a new terminal session and start tracking it."""
        config = SurfaceConfig(
            command=command,
            working_directory=working_directory or os.getcwd(),
            wait_after_command=command is not None,
            environment=environment or {},
        )

        if surface_type == "window":
            terminal_id = self._bridge.create_window(config)
        elif surface_type == "split":
            terminal_id = self._bridge.create_split(split_direction, config)
        else:
            terminal_id = self._bridge.create_tab(config)

        # Query Ghostty for the terminal's metadata.
        info = self._find_terminal(terminal_id)
        session = Session(
            terminal_id=terminal_id,
            name=info.name if info else "",
            working_directory=(
                info.working_directory if info else (working_directory or "")
            ),
            command=command,
        )
        self._sessions[terminal_id] = session
        return session

    def send_input(self, terminal_id: str, text: str) -> None:
        """Send text to a tracked session."""
        self._require_session(terminal_id)
        self._bridge.send_input(terminal_id, text)

    def read_output(self, terminal_id: str) -> str:
        """Read the screen contents of a tracked session."""
        self._require_session(terminal_id)
        return self._bridge.read_screen(terminal_id)

    def list_sessions(self) -> list[Session]:
        """Return all tracked sessions, pruning any that no longer exist."""
        dead = [
            tid
            for tid in self._sessions
            if not self._bridge.terminal_exists(tid)
        ]
        for tid in dead:
            del self._sessions[tid]
        return list(self._sessions.values())

    def discover_sessions(self) -> list[Session]:
        """Re-discover all Ghostty terminals and track them."""
        terminals = self._bridge.list_terminals()
        for info in terminals:
            if info.id not in self._sessions:
                self._sessions[info.id] = Session(
                    terminal_id=info.id,
                    name=info.name,
                    working_directory=info.working_directory,
                )
        return self.list_sessions()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _require_session(self, terminal_id: str) -> None:
        if terminal_id not in self._sessions:
            msg = (
                f"Unknown session: {terminal_id}. "
                "Use list_sessions or create_session first."
            )
            raise KeyError(msg)

    def _find_terminal(self, terminal_id: str) -> TerminalInfo | None:
        for t in self._bridge.list_terminals():
            if t.id == terminal_id:
                return t
        return None
