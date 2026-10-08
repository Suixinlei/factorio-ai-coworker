#!/usr/bin/env python3
"""Package and publish the Factorio AI Coworker mod to the Mod Portal.

The API key is read from FACTORIO_MOD_PORTAL_TOKEN or MOD_PORTAL_API_KEY.
Use --dry-run to build and inspect the release artifact without contacting
Factorio. The token is never printed.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD_PORTAL = "https://mods.factorio.com"
INIT_URL = f"{MOD_PORTAL}/api/v2/mods/init_publish"


def load_metadata(mod_dir: Path) -> dict[str, object]:
    with (mod_dir / "info.json").open(encoding="utf-8") as handle:
        metadata = json.load(handle)
    name = metadata.get("name")
    version = metadata.get("version")
    if name != "ai-coworker":
        raise SystemExit(f"mod/info.json name must be ai-coworker, got {name!r}")
    if not isinstance(version, str) or not version:
        raise SystemExit("mod/info.json must contain a non-empty version")
    return metadata


def build_zip(mod_dir: Path, output: Path, name: str, version: str) -> None:
    root_name = f"{name}_{version}"
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source in sorted(mod_dir.rglob("*")):
            if not source.is_file() or source.name.endswith(".pyc"):
                continue
            relative = source.relative_to(mod_dir)
            if "__pycache__" in relative.parts:
                continue
            archive.write(source, Path(root_name, relative).as_posix())


def request_json(url: str, *, data: bytes, headers: dict[str, str]) -> dict[str, object]:
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Factorio API request failed ({error.code}): {detail}") from error
    try:
        result = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit("Factorio API returned invalid JSON") from error
    if not isinstance(result, dict):
        raise SystemExit("Factorio API returned an unexpected response")
    if result.get("error"):
        raise SystemExit(f"Factorio API rejected request: {result.get('message', result['error'])}")
    return result


def multipart(fields: dict[str, str], file_name: str, file_bytes: bytes) -> tuple[bytes, str]:
    boundary = f"--------------------------{secrets.token_hex(12)}"
    chunks: list[bytes] = []
    for key, value in fields.items():
        chunks.extend([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode(),
            value.encode("utf-8"),
            b"\r\n",
        ])
    chunks.extend([
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{file_name}"\r\n'.encode(),
        f"Content-Type: {mimetypes.guess_type(file_name)[0] or 'application/zip'}\r\n\r\n".encode(),
        file_bytes,
        b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    return b"".join(chunks), boundary


def publish(upload_url: str, artifact: Path, description: str, source_url: str) -> dict[str, object]:
    body, boundary = multipart(
        {
            "description": description,
            "category": "utilities",
            "license": "default_mit",
            "source_url": source_url,
        },
        artifact.name,
        artifact.read_bytes(),
    )
    return request_json(
        upload_url,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="build the zip without uploading")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist", help="release artifact directory")
    parser.add_argument("--description-file", type=Path, default=ROOT / "mod" / "description.md")
    parser.add_argument("--source-url", default="https://github.com/Suixinlei/factorio-ai-coworker")
    args = parser.parse_args()

    mod_dir = ROOT / "mod"
    metadata = load_metadata(mod_dir)
    name = str(metadata["name"])
    version = str(metadata["version"])
    artifact = args.output_dir / f"{name}_{version}.zip"
    build_zip(mod_dir, artifact, name, version)
    print(f"Built {artifact} ({artifact.stat().st_size} bytes)")

    if args.dry_run:
        print("Dry run complete; no Factorio API request was made.")
        return 0

    token = os.environ.get("FACTORIO_MOD_PORTAL_TOKEN") or os.environ.get("MOD_PORTAL_API_KEY")
    if not token:
        raise SystemExit("Set FACTORIO_MOD_PORTAL_TOKEN (or MOD_PORTAL_API_KEY), or use --dry-run")
    description = args.description_file.read_text(encoding="utf-8")
    init = request_json(
        INIT_URL,
        data=urllib.parse.urlencode({"mod": name}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    upload_url = init.get("upload_url")
    if not isinstance(upload_url, str) or not upload_url.startswith(MOD_PORTAL):
        raise SystemExit("Factorio API did not return a valid upload URL")
    result = publish(upload_url, artifact, description, args.source_url)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
