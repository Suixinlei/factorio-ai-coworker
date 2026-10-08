"""CLI action/atomic-action migration smoke test against local Factorio."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = (ROOT / "local-server" / "rcon.pw").read_text(encoding="utf-8").strip()
BASE = [sys.executable, "-m", "cli", "--host", "127.0.0.1", "--port", "27016", "--password", PW]
COMPOUND = [
    "build_ghosts", "deconstruct", "clear_area", "plan_blueprint", "place_batch",
    "review_build", "clear_ghosts", "plan_mining_outpost", "gather", "fill",
    "collect", "deposit_to_chest", "return_home", "goto", "research",
]
ATOMIC = [
    "move", "mine", "place", "set_recipe", "craft", "pickup", "chat", "insert",
    "take", "summary", "wait",
]


def run(args: list[str]) -> dict:
    completed = subprocess.run(BASE + args, cwd=ROOT, text=True, capture_output=True, check=False)
    if not completed.stdout.strip():
        raise RuntimeError(completed.stderr)
    result = json.loads(completed.stdout)
    if completed.returncode != 0:
        raise RuntimeError(result)
    return result


def main() -> None:
    catalog = run(["catalog"])
    if set(COMPOUND) != set(catalog["skills"]):
        raise AssertionError((COMPOUND, catalog["skills"]))
    if set(ATOMIC) != set(catalog["primitives"]):
        raise AssertionError((ATOMIC, catalog["primitives"]))
    for name in COMPOUND + ATOMIC:
        result = run(["step", "--dry-run", json.dumps([{"action": name}])])
        assert result["ok"] and len(result["steps"]) == 1, (name, result)

    safe = [
        {"action": "deconstruct", "radius": 1},
        {"action": "review_build", "x": 5000, "y": 5000, "radius": 1},
        {"action": "clear_ghosts", "x": 5000, "y": 5000, "radius": 1},
        {"action": "move", "direction": "north", "distance": 0},
        {"action": "pickup", "position": {"x": 5000.5, "y": 5000.5}},
        {"action": "wait"},
    ]
    for action in safe:
        result = run(["--agent-id", "blueprint", "step", json.dumps([action])])
        assert result["attempted"] == 1, (action, result)
    print(json.dumps({"ok": True, "compound": len(COMPOUND), "atomic": len(ATOMIC), "safe_real": len(safe)}))


if __name__ == "__main__":
    main()
