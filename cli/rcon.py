"""Minimal RCON client used by the standalone Factorio CLI."""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Optional

log = logging.getLogger(__name__)
_MAX_COMMAND_LEN = 65535


def _lua_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, dict):
        return _lua_table(value)
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(_lua_value(item) for item in value) + "}"
    text = str(value).replace("\\", "\\\\").replace("'", "\\'")
    return f"'{text}'"


def _lua_table(values: dict[str, Any]) -> str:
    return "{" + ",".join(f"{key}={_lua_value(value)}" for key, value in values.items()) + "}"


class RCONGateway:
    def __init__(self, host: str, port: int, password: str):
        self._host = host
        self._port = port
        self._password = password
        self._client = None

    def connect(self) -> bool:
        try:
            from factorio_rcon import RCONClient
        except ImportError:
            log.error("factorio-rcon is not installed")
            return False
        try:
            self._client = RCONClient(self._host, self._port, self._password)
            return True
        except Exception as exc:
            log.warning("RCON connect failed: %s", exc)
            self._client = None
            return False

    @property
    def connected(self) -> bool:
        return self._client is not None

    def _send(self, command: str) -> str | None:
        if len(command) > _MAX_COMMAND_LEN:
            return None
        for attempt in range(2):
            if not self._client and not self.connect():
                return None
            try:
                result = self._client.send_command(command)
                return result if result is not None else ""
            except Exception as exc:
                log.warning("RCON send failed (attempt %d): %s", attempt + 1, exc)
                self._client = None
                if attempt == 0:
                    time.sleep(0.2)
        return None

    def query_lua(self, code: str) -> str | None:
        return self._send(f"/sc {code}")

    def _remote(self, method: str, *args: Any) -> Any:
        lua_args = ",".join(_lua_value(arg) for arg in args)
        suffix = ("," + lua_args) if lua_args else ""
        raw = self.query_lua(
            f"rcon.print(helpers.table_to_json(remote.call('ai_player','{method}'{suffix})))"
        )
        if raw is None:
            return {"error": "RCON send failed (is Factorio running?)"}
        try:
            return json.loads(raw.strip())
        except (ValueError, TypeError):
            return {"error": f"invalid {method} response: {raw[:200]}"}

    def create_agent(self, agent_id: str, name: str) -> dict[str, Any]:
        return self._remote("create_agent", agent_id, name)

    def spawn_ai_player(self, agent_id: str) -> bool:
        return bool(self._remote("spawn_agent", agent_id).get("ok"))

    def set_autonomy(self, enabled: bool, agent_id: str) -> dict[str, Any]:
        return self._remote("set_autonomy", agent_id, enabled)

    def set_coop(self, enabled: bool, agent_id: str) -> dict[str, Any]:
        return self._remote("set_coop", agent_id, enabled)

    def set_annotation(self, agent_id: str, annotation: dict[str, Any]) -> dict[str, Any]:
        return self._remote("set_annotation", agent_id, annotation)

    def run_batch_action(self, action: str, params: dict[str, Any], agent_id: str) -> dict[str, Any]:
        result = self._remote("run_batch_action", agent_id, action, params)
        return {"ok": bool(result.get("ok")), "detail": str(result.get("detail", result.get("error", "")))}

    def run_atomic_action(self, action: dict[str, Any], agent_id: str) -> dict[str, Any]:
        result = self._remote("run_atomic_action", agent_id, action)
        return {"ok": bool(result.get("ok")), "detail": str(result.get("detail", result.get("error", "")))}

    def run_query(self, name: str, params: dict[str, Any], agent_id: str) -> dict[str, Any]:
        return self._remote("query", agent_id, name, params)

    def get_factory_state(self, agent_id: str) -> dict[str, Any]:
        return self._remote("get_state", agent_id)

    def list_batch_actions(self) -> list[str]:
        value = self._remote("list_batch_actions")
        if not isinstance(value, list):
            raise RuntimeError(str(value.get("error", value)) if isinstance(value, dict) else str(value))
        return value

    def list_atomic_actions(self) -> list[str]:
        value = self._remote("list_atomic_actions")
        if not isinstance(value, list):
            raise RuntimeError(str(value.get("error", value)) if isinstance(value, dict) else str(value))
        return value

    def list_queries(self) -> list[str]:
        value = self._remote("list_queries")
        if not isinstance(value, list):
            raise RuntimeError(str(value.get("error", value)) if isinstance(value, dict) else str(value))
        return value
