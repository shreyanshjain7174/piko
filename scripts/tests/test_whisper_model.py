import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "model_assets", Path(__file__).resolve().parents[1] / "prepare-whisper-model.py")
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class WhisperModelTests(unittest.TestCase):
    def test_paths_cannot_escape_staging_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                assets.asset_path(Path(folder), "../outside")
            with self.assertRaises(ValueError):
                assets.asset_path(Path(folder), "/outside")

    def test_missing_or_empty_manifest_is_not_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(OSError):
                assets.verify(root)
            (root / "manifest.json").write_text(json.dumps({
                "model_revision": assets.MODEL_REVISION,
                "tokenizer_revision": assets.TOKENIZER_REVISION,
                "files": {},
            }))
            with self.assertRaises(ValueError):
                assets.verify(root)

    def test_revision_mismatch_is_not_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "manifest.json").write_text(json.dumps({
                "model_revision": "different",
                "tokenizer_revision": assets.TOKENIZER_REVISION,
                "files": {},
            }))
            with self.assertRaises(ValueError):
                assets.verify(root)

    def test_cache_cannot_replace_source_pinned_checksums(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            manifest = json.loads(
                Path(assets.__file__).with_name("whisper-model-manifest.json").read_text())
            manifest["files"]["Tokenizer/tokenizer.json"]["sha256"] = "0" * 64
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                assets.verify(root)

    def test_uninspected_files_cannot_shadow_pinned_assets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "manifest.json").write_text(
                Path(assets.__file__).with_name("whisper-model-manifest.json").read_text())
            (root / "uninspected-tokenizer.json").write_text("{}")
            with self.assertRaises(ValueError):
                assets.verify(root)
