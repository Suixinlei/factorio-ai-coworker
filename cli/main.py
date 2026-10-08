"""One-shot CLI for the Factorio AI Coworker RCON facade.

Every invocation loads the current ``cli/.env`` and ``FACTORIO_RCON_*`` environment values,
opens RCON, performs one operation, prints JSON, and exits.  Changing the
server target therefore does not require restarting a client application.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

from .config import ConfigLoader
from .rcon import RCONGateway


BATCH_ACTIONS = {
    "batch_build_ghost", "batch_mine", "batch_create_ghost",
    "batch_review_build", "batch_remove_ghost",
    "batch_insert", "batch_take", "batch_pickup",
}
ATOMIC_ACTIONS = {
    "move", "mine", "place", "set_recipe", "craft", "pickup", "chat",
    "goto", "research", "insert", "take", "summary", "wait",
    "create_ghost", "build_ghost", "remove_ghost", "review_build",
    "shoot", "add_note", "view_notes", "create_todo", "add_todo",
    "complete_todo", "view_todo",
}
QUERIES = {
    "can_place", "get_recipe", "get_resource_patch", "inspect_entity",
    "get_enemies", "get_character_state", "get_chart_tags",
    "nearest_buildable", "scan_area",
}


class UsageError(ValueError):
    pass


def emit(value: Any, pretty: bool) -> None:
    if pretty:
        print(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2))
    else:
        print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def parse_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise UsageError(f"{label} must be valid JSON: {exc.msg}") from exc


def parse_object(raw: str, label: str) -> dict[str, Any]:
    value = parse_json(raw, label)
    if not isinstance(value, dict):
        raise UsageError(f"{label} must be a JSON object")
    return value


def state_hash(state: dict[str, Any]) -> str:
    stable = {k: v for k, v in state.items() if k != "tick"}
    raw = json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def _canonical_compound(name: str) -> str:
    return name.strip().lower()


def _read_action_file(raw_path: str, base_dir: Path, action: str) -> dict[str, Any]:
    path = Path(raw_path)
    if not path.is_absolute():
        path = base_dir / path
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise UsageError(f"action file '{path}' could not be read: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise UsageError(f"action file '{path}' must be valid JSON: {exc.msg}") from exc
    if isinstance(payload, list):
        if action in {"batch_create_ghost", "batch_build_ghost"}:
            return {"entities": payload}
        if action == "batch_mine":
            return {"areas": payload}
        raise UsageError(f"action file lists are only supported for {action}=entities/areas")
    if not isinstance(payload, dict):
        raise UsageError(f"action file '{path}' must contain a JSON object or array")
    return payload


def _expand_action_files(steps: list[dict[str, Any]], base_dir: Path) -> list[dict[str, Any]]:
    expanded: list[dict[str, Any]] = []
    for item in steps:
        item = dict(item)
        key = "action"
        name = item[key]
        if "file" in item:
            payload = _read_action_file(str(item.pop("file")), base_dir, name)
            payload.update(item)
            item = {key: name, **payload}
        # The Factorio-side batch handlers cap explicit entity lists at 500.
        # Split a file-backed blueprint into valid requests automatically.
        entities = item.get("entities")
        if (name in {"batch_create_ghost", "batch_build_ghost"}
                and isinstance(entities, list) and len(entities) > 500
                and item.get("use") is None):
            for start in range(0, len(entities), 500):
                part = dict(item)
                part["entities"] = entities[start:start + 500]
                expanded.append(part)
        else:
            expanded.append(item)
    return expanded


def validate_steps(value: Any, *, max_steps: int = 4,
                   file_base_dir: Path | None = None) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise UsageError("steps must be a non-empty JSON array")
    if len(value) > max_steps:
        raise UsageError(f"at most {max_steps} steps are allowed")
    result = []
    for index, item in enumerate(value):
        if not isinstance(item, dict) or "action" not in item or "skill" in item:
            raise UsageError(f"step {index} needs exactly one action key")
        item = dict(item)
        name = _canonical_compound(str(item["action"]))
        if name not in BATCH_ACTIONS and name not in ATOMIC_ACTIONS:
            raise UsageError(f"unsupported action '{name}'")
        item["action"] = name
        result.append(item)
    if file_base_dir is not None:
        result = _expand_action_files(result, file_base_dir)
        if len(result) > max_steps:
            raise UsageError(f"action file expands to {len(result)} steps; limit is {max_steps}")
    return result


class Client:
    def __init__(self, args: argparse.Namespace):
        cfg = ConfigLoader().get()
        host = args.host or cfg.rcon.host
        port = args.port if args.port is not None else cfg.rcon.port
        password = args.password if args.password is not None else cfg.rcon.password
        self.gateway = RCONGateway(host, port, password)
        self.target = f"{host}:{port}"
        self.agent_id = (args.agent_id or os.environ.get("FACTORIO_AGENT_ID") or "").strip()

    def require_agent(self) -> None:
        if not self.agent_id:
            raise UsageError("a role is required; use --agent-id or session bind")

    def status(self) -> dict[str, Any]:
        self.gateway.connect()
        return {"connected": self.gateway.connected, "target": self.target,
                "agent_id": self.agent_id or None}

    def session(self, args: argparse.Namespace) -> Any:
        action = args.session_action
        if action == "list":
            raw = self.gateway.query_lua(
                "rcon.print(helpers.table_to_json(remote.call('ai_player','list_agents')))"
            )
            if raw is None:
                raise RuntimeError("RCON unavailable")
            try:
                return json.loads(raw.strip())
            except json.JSONDecodeError:
                return raw.strip()
        if action == "bind":
            name = (args.name or "").strip()
            chosen = (args.session_agent_id or self.agent_id or "").strip()
            chosen = chosen or re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-")
            if not chosen:
                raise UsageError("session bind requires --name or --agent-id")
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", chosen):
                raise UsageError("agent_id must contain 1-64 ASCII letters, digits, _ or -")
            result = self.gateway.create_agent(chosen, name or chosen)
            if result.get("error") and "already exists" in result["error"]:
                return {"ok": True, "agent_id": chosen, "rebound": True}
            return result
        self.require_agent()
        if action == "spawn":
            return {"ok": self.gateway.spawn_ai_player(self.agent_id), "agent_id": self.agent_id}
        if action in {"autonomy", "coop"}:
            if args.enabled is None:
                raise UsageError("use --enable or --disable")
            if action == "autonomy":
                return self.gateway.set_autonomy(args.enabled, self.agent_id)
            return self.gateway.set_coop(args.enabled, self.agent_id)
        raise UsageError(f"unknown session action '{action}'")

    def state(self, detail: str) -> dict[str, Any]:
        self.require_agent()
        result = self.gateway.get_factory_state(self.agent_id)
        if result.get("error"):
            raise RuntimeError(result["error"])
        result["agent_id"] = self.agent_id
        result["state_hash"] = state_hash(result)
        if detail == "brief" and isinstance(result.get("factory"), dict):
            factory = result["factory"]
            result["factory"] = {k: factory[k] for k in
                                  ("total", "by_type", "by_status", "attention") if k in factory}
        return result

    def map(self, args: argparse.Namespace) -> Any:
        self.require_agent()
        params: dict[str, Any] = {"width": args.width, "height": args.height}
        if (args.x is None) != (args.y is None):
            raise UsageError("map requires both --x and --y")
        if args.x is not None:
            params.update(x=args.x, y=args.y)
        return self.gateway.run_query("scan_area", params, self.agent_id)

    def query(self, args: argparse.Namespace) -> Any:
        self.require_agent()
        params = parse_object(args.params, "--params") if args.params else {}
        return self.gateway.run_query(args.kind, params, self.agent_id)

    def catalog(self) -> dict[str, Any]:
        return {
            "batch_actions": self.gateway.list_batch_actions(),
            "atomic_actions": self.gateway.list_atomic_actions(),
            "queries": self.gateway.list_queries(),
        }

    def annotate(self, args: argparse.Namespace) -> Any:
        self.require_agent()
        if args.map_tag and args.map_tag_json:
            raise UsageError("use only one of --map-tag and --map-tag-json")
        spec: dict[str, Any] = {"clear": args.clear, "clear_tags": args.clear_tags}
        if args.label is not None:
            spec["label"] = args.label
        if args.icon is not None:
            spec["icon"] = args.icon
        if args.map_tag is not None:
            spec["map_tag"] = args.map_tag
        if args.map_tag_json is not None:
            spec["map_tag"] = parse_object(args.map_tag_json, "--map-tag-json")
        if len(spec) == 2 and not (args.clear or args.clear_tags):
            raise UsageError("provide an annotation field or --clear/--clear-tags")
        return self.gateway.set_annotation(self.agent_id, spec)

    def step(self, args: argparse.Namespace) -> Any:
        raw = Path(args.file).read_text(encoding="utf-8") if args.file else args.steps
        if bool(args.file) == bool(args.steps):
            raise UsageError("provide exactly one STEPS argument or --file")
        value = parse_json(raw, "steps")
        if isinstance(value, dict) and isinstance(value.get("steps"), list):
            value = value["steps"]
        steps = validate_steps(
            value,
            max_steps=256 if args.file else 4,
            file_base_dir=Path(args.file).resolve().parent if args.file else Path.cwd(),
        )
        if args.dry_run:
            return {"ok": True, "dry_run": True, "steps": steps}
        self.require_agent()
        before = self.gateway.get_factory_state(self.agent_id)
        if before.get("error"):
            raise RuntimeError(before["error"])
        actual = state_hash(before)
        if args.expected_state and args.expected_state != actual:
            return {"ok": False, "reason": "state_changed", "expected": args.expected_state, "actual": actual}
        results = []
        for index, item in enumerate(steps):
            call = dict(item)
            name = call.pop("action")
            result = (self.gateway.run_batch_action(name, call, self.agent_id)
                      if name in BATCH_ACTIONS else self.gateway.run_atomic_action({"action": name, **call}, self.agent_id))
            row = {"step": index, "name": name, **result}
            results.append(row)
            if args.stop_on_failure and not row.get("ok"):
                break
        response: dict[str, Any] = {
            "ok": len(results) == len(steps) and all(row.get("ok") for row in results),
            "completed": sum(bool(row.get("ok")) for row in results),
            "attempted": len(results), "results": results,
        }
        if not response["ok"]:
            response["failed_at"] = next((r["step"] for r in results if not r.get("ok")), len(results))
        after = self.gateway.get_factory_state(self.agent_id)
        if not after.get("error"):
            response["state_hash"] = state_hash(after)
        return response


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="factorio", description="Factorio AI Coworker CLI")
    p.add_argument("--host", help="RCON host; overrides FACTORIO_RCON_HOST")
    p.add_argument("--port", type=int, help="RCON port; overrides FACTORIO_RCON_PORT")
    p.add_argument("--password", help="RCON password; overrides FACTORIO_RCON_PASSWORD")
    p.add_argument("--agent-id", help="role id; overrides FACTORIO_AGENT_ID")
    p.add_argument("--pretty", action="store_true")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("catalog", help="list server batch actions, atomic actions, and queries")
    session = sub.add_parser("session")
    ss = session.add_subparsers(dest="session_action", required=True)
    ss.add_parser("list")
    bind = ss.add_parser("bind")
    bind.add_argument("--name")
    bind.add_argument("--agent-id", dest="session_agent_id")
    ss.add_parser("spawn")
    for action in ("autonomy", "coop"):
        q = ss.add_parser(action)
        group = q.add_mutually_exclusive_group(required=True)
        group.add_argument("--enable", dest="enabled", action="store_true")
        group.add_argument("--disable", dest="enabled", action="store_false")
    state = sub.add_parser("state")
    state.add_argument("--detail", choices=("brief", "full"), default="brief")
    scan = sub.add_parser("map")
    scan.add_argument("--x", type=float)
    scan.add_argument("--y", type=float)
    scan.add_argument("--width", type=int, default=64)
    scan.add_argument("--height", type=int, default=64)
    query = sub.add_parser("query")
    query.add_argument("kind", choices=sorted(QUERIES))
    query.add_argument("--params")
    annotate = sub.add_parser("annotate")
    annotate.add_argument("--label")
    annotate.add_argument("--map-tag")
    annotate.add_argument("--map-tag-json")
    annotate.add_argument("--icon")
    annotate.add_argument("--clear", action="store_true")
    annotate.add_argument("--clear-tags", action="store_true")
    step = sub.add_parser("step")
    step.add_argument("steps", nargs="?")
    step.add_argument("--file")
    step.add_argument("--dry-run", action="store_true")
    step.add_argument("--continue-on-failure", dest="stop_on_failure", action="store_false")
    step.add_argument("--expected-state", default="")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        client = Client(args)
        if args.command == "status":
            result = client.status()
        elif args.command == "catalog":
            result = client.catalog()
        elif args.command == "session":
            result = client.session(args)
        elif args.command == "state":
            result = client.state(args.detail)
        elif args.command == "map":
            result = client.map(args)
        elif args.command == "query":
            result = client.query(args)
        elif args.command == "annotate":
            result = client.annotate(args)
        elif args.command == "step":
            result = client.step(args)
        else:  # argparse makes this unreachable
            raise UsageError(f"unknown command {args.command}")
        emit(result, args.pretty)
        return 0
    except (UsageError, OSError, RuntimeError, ValueError) as exc:
        emit({"ok": False, "error": str(exc)}, args.pretty)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
