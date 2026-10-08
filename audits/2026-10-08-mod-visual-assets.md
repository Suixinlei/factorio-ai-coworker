# Mod visual assets verification

Date: 2026-10-08

The Factorio mod package now contains a 144×144 `thumbnail.png` for the Mod
Portal icon and a wide CLI/RCON demonstration image for the description page.

## Reproduction

From the repository root:

```bash
python3 scripts/publish-mod.py --dry-run --output-dir /tmp/ai-coworker-dist
unzip -l /tmp/ai-coworker-dist/ai-coworker_0.1.0.zip \
  | rg 'thumbnail|ai-coworker-cli-rcon-demo|description.md'
sips -g pixelWidth -g pixelHeight mod/thumbnail.png \
  mod/assets/ai-coworker-cli-rcon-demo.png
```

## Results

- Dry-run packaging completed successfully without a Mod Portal API request.
- The archive contains `thumbnail.png`, `assets/ai-coworker-cli-rcon-demo.png`,
  and the updated `description.md`.
- `thumbnail.png` is 144×144 pixels.
- The demonstration image is 1672×941 pixels (16:9) and depicts Codex, Claude
  Code, and OpenCode connecting through CLI/RCON to AI Coworker roles.
