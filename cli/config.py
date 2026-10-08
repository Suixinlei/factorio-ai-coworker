"""Runtime configuration for the standalone Factorio CLI."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _load_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


@dataclass(frozen=True)
class RCONConfig:
    host: str = "localhost"
    port: int = 27015
    password: str = ""


class ConfigLoader:
    """Read CLI credentials fresh for each process invocation.

    Environment variables are authoritative. ``cli/.env`` and a repository
    root ``.env`` are supported for local use.
    """

    def __init__(self) -> None:
        root = Path(__file__).resolve().parent.parent
        merged: dict[str, str] = {}
        for path in (root / ".env", root / "cli" / ".env"):
            merged.update(_load_env(path))
        for key in ("FACTORIO_RCON_HOST", "FACTORIO_RCON_PORT", "FACTORIO_RCON_PASSWORD"):
            if key in os.environ:
                merged[key] = os.environ[key]
        self.rcon = RCONConfig(
            host=merged.get("FACTORIO_RCON_HOST", "localhost"),
            port=int(merged.get("FACTORIO_RCON_PORT", "27015")),
            password=merged.get("FACTORIO_RCON_PASSWORD", ""),
        )

    def get(self) -> "ConfigLoader":
        """Return the loaded configuration for compatibility with the CLI."""
        return self
