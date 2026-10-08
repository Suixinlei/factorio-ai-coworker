# Factorio AI Coworker

Factorio AI Coworker (AI 协作者) is an open-source toolkit for building and coordinating AI-controlled players in Factorio. It combines an in-game mod with a small, one-shot RCON CLI so agents can inspect the world, keep stable player identities, and execute bounded batch actions, atomic actions, and queries.

The project is **inspired by [ai-player-v3](https://github.com/Suixinlei/factorio-ai-player-workspace)** and uses `ai-coworker` as the Factorio mod name and repository name. The project name is `factorio-ai-coworker`; the earlier project is credited as inspiration.

[中文说明](README.zh-CN.md)

## What is included

- `mod/`: the Factorio 2.0 mod with dynamic AI players, batch actions, atomic actions, queries, and annotations.
- `cli/`: an independent command-line client. Each invocation reads the current RCON settings and exits after one operation.
- `skills/`: operating rules and local headless-server guidance for AI agents.
- `audits/`: reproducible end-to-end verification notes and scripts.
- `scripts/local-headless.sh`: a local Factorio headless-server launcher that packages the mod automatically.

## Quick start

Create a local environment and provide the RCON settings through environment variables or `cli/.env`:

```bash
FACTORIO_RCON_HOST=127.0.0.1
FACTORIO_RCON_PORT=27016
FACTORIO_RCON_PASSWORD=your-password
```

Then run commands from the repository root:

```bash
.venv/bin/python -m cli status
.venv/bin/python -m cli catalog
.venv/bin/python -m cli session list
.venv/bin/python -m cli --agent-id builder state
.venv/bin/python -m cli --agent-id builder map --width 64 --height 64
.venv/bin/python -m cli --agent-id builder query get_recipe \
  --params '{"name":"iron-gear-wheel"}'
.venv/bin/python -m cli --agent-id builder step \
  '[{"action":"batch_mine","item":"iron-ore","count":50}]'
```

Use [`cli/README.md`](cli/README.md) for the complete command reference. Never commit real credentials; `.env` files and local server data are ignored by Git.

## Local headless server

Run `./scripts/local-headless.sh` to package the current `mod/` tree and start a local server. The default game port is `127.0.0.1:34198` and the default RCON port is `127.0.0.1:27016`. The full development loop is documented in [`skills/factorio-local-dev/SKILL.md`](skills/factorio-local-dev/SKILL.md).

## Safety model

Agent operations are deliberately bounded. Batch actions and atomic actions are allow-listed, queries return structured data, and the CLI requires an explicit `agent_id` for player-scoped actions. Review [`skills/factorio-ai-coworker/SKILL.md`](skills/factorio-ai-coworker/SKILL.md) before connecting an agent to a live server.

## Publish to the Factorio Mod Portal

The repository includes [`scripts/publish-mod.py`](scripts/publish-mod.py). It builds the required `ai-coworker_<version>.zip` layout and can publish it through Factorio's Mod Publish API:

```bash
python3 scripts/publish-mod.py --dry-run
export FACTORIO_MOD_PORTAL_TOKEN=your-mod-portal-api-key
python3 scripts/publish-mod.py
```

Create an API key on your Factorio account with the `ModPortal: Publish Mods` permission. The script sends the release description, `utilities` category, MIT license, and this GitHub source URL. Never commit the API key.

## Verification

The repository records local RCON end-to-end checks in [`audits/`](audits/). For example, [`audits/2026-10-08-factorio-cli-e2e.md`](audits/2026-10-08-factorio-cli-e2e.md) documents the CLI smoke run and its results.

## License

Factorio AI Coworker is released under the [MIT License](LICENSE).
