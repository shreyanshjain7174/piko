#!/usr/bin/env python3
"""Explicitly download or verify the single pinned local Whisper benchmark model."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

MODEL_REPO = "argmaxinc/whisperkit-coreml"
MODEL_REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
MODEL_PREFIX = "openai_whisper-large-v3-v20240930_626MB/"
TOKENIZER_REPO = "openai/whisper-large-v3-turbo"
TOKENIZER_REVISION = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
TOKENIZER_FILES = {
    "tokenizer.json", "tokenizer_config.json", "config.json",
    "special_tokens_map.json", "added_tokens.json",
}


def asset_path(root, relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"Invalid asset path: {relative}")
    destination = root.joinpath(*path.parts)
    if not destination.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Asset path escapes model directory: {relative}")
    return destination


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(root):
    manifest = json.loads((root / "manifest.json").read_text())
    pinned = json.loads(Path(__file__).with_name("whisper-model-manifest.json").read_text())
    if (manifest["model_revision"] != MODEL_REVISION
            or manifest["tokenizer_revision"] != TOKENIZER_REVISION):
        raise ValueError("Model manifest does not match the pinned revisions")
    assets = manifest["files"]
    if assets != pinned["files"]:
        raise ValueError("Asset manifest does not match the source-pinned sizes and SHA-256 hashes")
    actual = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("Model assets must not contain symbolic links")
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    if actual != set(assets) | {"manifest.json"}:
        raise ValueError("Model folder contains missing or uninspected files")
    if not assets:
        raise ValueError("Model manifest contains no assets")
    required = {
        "AudioEncoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/weights/weight.bin",
        "Tokenizer/tokenizer.json", "Tokenizer/tokenizer_config.json",
    }
    if not required.issubset(assets):
        raise ValueError("Model manifest is incomplete")
    for relative, expected in assets.items():
        path = asset_path(root, relative)
        if path.stat().st_size != expected["size"] or sha256(path) != expected["sha256"]:
            raise ValueError(f"Asset verification failed: {relative}")
    return len(assets)


def repository_files(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        metadata = json.load(response)
    if metadata["sha"] != revision:
        raise ValueError(f"Repository revision changed: {repo}")
    return metadata["siblings"]


def download(root):
    entries = []
    for item in repository_files(MODEL_REPO, MODEL_REVISION):
        if item["rfilename"].startswith(MODEL_PREFIX):
            entries.append((MODEL_REPO, MODEL_REVISION, item, item["rfilename"][len(MODEL_PREFIX):]))
    tokenizer = [
        item for item in repository_files(TOKENIZER_REPO, TOKENIZER_REVISION)
        if item["rfilename"] in TOKENIZER_FILES
    ]
    if {item["rfilename"] for item in tokenizer} != TOKENIZER_FILES:
        raise ValueError("Pinned tokenizer files are incomplete")
    entries.extend((TOKENIZER_REPO, TOKENIZER_REVISION, item, "Tokenizer/" + item["rfilename"])
                   for item in tokenizer)
    root.mkdir(parents=True, exist_ok=True)
    total = sum(item["size"] for _, _, item, _ in entries)
    if shutil.disk_usage(root).free < total + 512 * 1024 * 1024:
        raise ValueError("Insufficient space for model assets and verification")
    manifest = {"model_revision": MODEL_REVISION, "tokenizer_revision": TOKENIZER_REVISION, "files": {}}
    for repo, revision, item, relative in entries:
        target = asset_path(root, relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".partial")
        url = f"https://huggingface.co/{repo}/resolve/{revision}/" + urllib.parse.quote(item["rfilename"])
        print(f"Downloading {relative} ({item['size']} bytes)", flush=True)
        try:
            with urllib.request.urlopen(url, timeout=120) as source, partial.open("wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            if partial.stat().st_size != item["size"]:
                raise ValueError(f"Incomplete download: {relative}")
            digest = sha256(partial)
            expected = item.get("lfs", {}).get("sha256")
            if expected:
                if digest != expected:
                    raise ValueError(f"SHA-256 mismatch: {relative}")
            else:
                blob = hashlib.sha1(f"blob {item['size']}\0".encode())
                with partial.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        blob.update(chunk)
                if blob.hexdigest() != item["blobId"]:
                    raise ValueError(f"Pinned Git object mismatch: {relative}")
            os.replace(partial, target)
            manifest["files"][relative] = {"size": item["size"], "sha256": digest}
        finally:
            partial.unlink(missing_ok=True)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return verify(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--download", action="store_true", help="explicitly fetch pinned public assets")
    args = parser.parse_args()
    try:
        count = download(args.folder) if args.download else verify(args.folder)
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError) as error:
        print(f"Whisper assets unavailable: {error}", file=sys.stderr)
        return 1
    print(f"Verified {count} assets. No recognition or device-quality claim.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
