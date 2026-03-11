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
        config = config or SurfaceConfig()
        config_block = self._build_config_block(config)
        script = f"""\
tell application "Ghostty"
    {config_block}
    new tab in front window with configuration cfg
    delay 0.3
    set termId to id of focused terminal of selected tab of front window
    return termId
end tell"""
        return self._run_applescript(script)

    def create_window(self, config: SurfaceConfig | None = None) -> str:
        """Open a new window and return its terminal id."""
        config = config or SurfaceConfig()
        config_block = self._build_config_block(config)
        script = f"""\
tell application "Ghostty"
    {config_block}
    new window with configuration cfg
    delay 0.3
    set termId to id of focused terminal of selected tab of front window
    return termId
end tell"""
        return self._run_applescript(script)

    def create_split(
        self,
        direction: str = "right",
        config: SurfaceConfig | None = None,
    ) -> str:
        """Open a new split and return its terminal id."""
        config = config or SurfaceConfig()
        config_block = self._build_config_block(config)
        script = f"""\
tell application "Ghostty"
    {config_block}
    set currentTerm to focused terminal of selected tab of front window
    set t2 to split currentTerm direction {direction} with configuration cfg
    delay 0.3
    set termId to id of focused terminal of selected tab of front window
    return termId
end tell"""
        return self._run_applescript(script)

    @staticmethod
    def _build_config_block(config: SurfaceConfig) -> str:
        lines = ["set cfg to new surface configuration"]
        if config.command:
            escaped = config.command.replace('"', '\\"')
            lines.append(f'set command of cfg to "{escaped}"')
        if config.working_directory:
            escaped = config.working_directory.replace('"', '\\"')
            lines.append(
                f'set initial working directory of cfg to "{escaped}"',
            )
        if config.initial_input:
            escaped = config.initial_input.replace('"', '\\"')
            lines.append(
                f'set initial input of cfg to "{escaped}"',
            )
        if config.wait_after_command:
            lines.append("set wait after command of cfg to true")
        if config.environment:
            env_items = [
                f'"{k.replace(chr(34), chr(92)+chr(34))}={v.replace(chr(34), chr(92)+chr(34))}"'
                for k, v in config.environment.items()
            ]
            env_list = ", ".join(env_items)
            lines.append(
                f"set environment variables of cfg to {{{env_list}}}",
            )
        return "\n    ".join(lines)

    # ------------------------------------------------------------------
    # Input / Output
    # ------------------------------------------------------------------

    def send_input(self, terminal_id: str, text: str) -> None:
        """Send text input to a terminal.

        The special token ``<>enter<>`` is converted to a ``send key "enter"``
        event, allowing callers to submit commands while still supporting
        literal newlines via ``input text``.
        """
        parts = text.split("<>enter<>")
        commands: list[str] = []
        for i, part in enumerate(parts):
            if part:
                escaped = part.replace("\\", "\\\\").replace('"', '\\"')
                commands.append(f'input text "{escaped}" to term')
            if i < len(parts) - 1:
                commands.append('send key "enter" to term')
        actions = "\n                    ".join(commands)
        script = f"""\
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                if id of term is "{terminal_id}" then
                    {actions}
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
