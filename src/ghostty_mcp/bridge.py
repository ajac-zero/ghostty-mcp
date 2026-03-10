"""Thin wrapper over osascript subprocess calls to control Ghostty."""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class TerminalInfo:
    """Info returned by Ghostty for a terminal."""

    id: str
    name: str
    working_directory: str


@dataclass
class SurfaceConfig:
    """Maps to Ghostty's `new surface configuration`."""

    command: str | None = None
    working_directory: str | None = None
    initial_input: str | None = None
    wait_after_command: bool = False
    environment: dict[str, str] = field(default_factory=dict)


class GhosttyBridge:
    """Execute AppleScript commands against Ghostty.app via osascript."""

    # Delay after write_screen_file before reading clipboard (seconds).
    CLIPBOARD_DELAY: float = 0.15

    # ------------------------------------------------------------------
    # Low-level helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _run_applescript(script: str) -> str:
        result = subprocess.run(  # noqa: S603
            ["osascript", "-e", script],  # noqa: S607
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            msg = f"osascript failed: {result.stderr.strip()}"
            raise RuntimeError(msg)
        return result.stdout.strip()

    @staticmethod
    def _get_clipboard() -> str:
        result = subprocess.run(
            ["pbpaste"],  # noqa: S607
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        return result.stdout

    @staticmethod
    def _set_clipboard(text: str) -> None:
        subprocess.run(
            ["pbcopy"],  # noqa: S607
            input=text,
            text=True,
            timeout=5,
            check=True,
        )

    # ------------------------------------------------------------------
    # Terminal queries
    # ------------------------------------------------------------------

    def list_terminals(self) -> list[TerminalInfo]:
        """Return info for every terminal across all windows/tabs."""
        script = """\
tell application "Ghostty"
    set out to ""
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                set out to out & id of term & "\\t" ¬
                    & name of term & "\\t" ¬
                    & working directory of term & "\\n"
            end repeat
        end repeat
    end repeat
    return out
end tell"""
        raw = self._run_applescript(script)
        terminals: list[TerminalInfo] = []
        for line in raw.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:  # noqa: PLR2004
                terminals.append(
                    TerminalInfo(
                        id=parts[0],
                        name=parts[1],
                        working_directory=parts[2],
                    ),
                )
        return terminals

    def terminal_exists(self, terminal_id: str) -> bool:
        """Check whether a terminal with the given id still exists."""
        try:
            script = f"""\
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                if id of term is "{terminal_id}" then return true
            end repeat
        end repeat
    end repeat
    return false
end tell"""
            return self._run_applescript(script) == "true"
        except RuntimeError:
            return False

    # ------------------------------------------------------------------
    # Session creation
    # ------------------------------------------------------------------

    def create_tab(self, config: SurfaceConfig | None = None) -> str:
        """Open a new tab and return its terminal id."""
        return self._create_surface("new tab", config)

    def create_window(self, config: SurfaceConfig | None = None) -> str:
        """Open a new window and return its terminal id."""
        return self._create_surface("new window", config)

    def create_split(
        self,
        direction: str = "right",
        config: SurfaceConfig | None = None,
    ) -> str:
        """Open a new split and return its terminal id."""
        return self._create_surface(f"split direction {direction}", config)

    def _create_surface(
        self,
        command: str,
        config: SurfaceConfig | None,
    ) -> str:
        if config:
            config_block = self._build_config_block(config)
            script = f"""\
tell application "Ghostty"
    {config_block}
    {command} with surfaceConfig
    set termId to id of focused terminal of front window
    return termId
end tell"""
        else:
            script = f"""\
tell application "Ghostty"
    {command}
    set termId to id of focused terminal of front window
    return termId
end tell"""
        return self._run_applescript(script)

    @staticmethod
    def _build_config_block(config: SurfaceConfig) -> str:
        lines = ["set surfaceConfig to new surface configuration"]
        if config.command:
            escaped = config.command.replace('"', '\\"')
            lines.append(f'set command of surfaceConfig to "{escaped}"')
        if config.working_directory:
            escaped = config.working_directory.replace('"', '\\"')
            lines.append(
                f'set initial working directory of surfaceConfig to "{escaped}"',
            )
        if config.initial_input:
            escaped = config.initial_input.replace('"', '\\"')
            lines.append(
                f'set initial input of surfaceConfig to "{escaped}"',
            )
        if config.wait_after_command:
            lines.append("set wait after command of surfaceConfig to true")
        for key, value in config.environment.items():
            k = key.replace('"', '\\"')
            v = value.replace('"', '\\"')
            lines.append(
                "set environment of surfaceConfig to"
                f' environment of surfaceConfig & {{"{k}={v}"}}',
            )
        return "\n    ".join(lines)

    # ------------------------------------------------------------------
    # Input / Output
    # ------------------------------------------------------------------

    def send_input(self, terminal_id: str, text: str) -> None:
        """Send text input to a terminal."""
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        script = f"""\
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                if id of term is "{terminal_id}" then
                    input text "{escaped}" to term
                    return
                end if
            end repeat
        end repeat
    end repeat
    error "Terminal not found: {terminal_id}"
end tell"""
        self._run_applescript(script)

    def read_screen(self, terminal_id: str) -> str:
        """Read screen contents using the write_screen_file workaround.

        Saves/restores clipboard. Cleans up the temp file.
        """
        saved_clipboard = self._get_clipboard()
        try:
            script = f"""\
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                if id of term is "{terminal_id}" then
                    perform action "write_screen_file:copy" on term
                    return
                end if
            end repeat
        end repeat
    end repeat
    error "Terminal not found: {terminal_id}"
end tell"""
            self._run_applescript(script)
            time.sleep(self.CLIPBOARD_DELAY)
            file_path = self._get_clipboard().strip()
            if not file_path or not Path(file_path).exists():
                msg = (
                    "Failed to read screen: could not retrieve temp file path "
                    "from clipboard."
                )
                raise RuntimeError(msg)
            path = Path(file_path)
            contents = path.read_text()
            path.unlink(missing_ok=True)
        finally:
            self._set_clipboard(saved_clipboard)
        return contents
