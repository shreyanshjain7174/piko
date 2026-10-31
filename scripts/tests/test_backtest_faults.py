import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "backtest.py"


def corpus_hash(entries):
    ordered = sorted(entries)
    return hashlib.sha256(json.dumps(ordered, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


class BacktestFaultTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.audio = self.root / "one.wav"
        self.audio.write_bytes(b"synthetic fixture only")
        self.digest = hashlib.sha256(self.audio.read_bytes()).hexdigest()
        self.references = {"corpus_id": "synthetic", "locale": "en-IN", "utterances": [
            {"id": "one", "filename": "one.wav", "sha256": self.digest, "reference": "hello world"}
        ]}
        self.results = [{"fixture": "one.wav", "engine": "SpeechTranscriberEngine",
                         "locale": "en-IN", "audioSHA256": self.digest,
                         "transcript": "hello world", "inputDurationMS": 120,
                         "preparationMS": 10, "firstHypothesisFromFileStartMS": 20,
                         "finalizationMS": 30}]
        self.manifest = {"schema": 1, "engine": "apple", "engineVersion": "synthetic-1",
                         "locale": "en-IN", "device": "synthetic", "iosBuild": "synthetic",
                         "runKind": "cold", "corpus": {"id": "synthetic",
                         "sha256": corpus_hash([["one.wav", self.digest, "hello world"]]),
                         "split": "baseline"}, "references": "references.json",
                         "results": "results.json"}

    def run_backtest(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        (self.root / "references.json").write_text(json.dumps(self.references))
        (self.root / "results.json").write_text(json.dumps(self.results))
        return subprocess.run([sys.executable, "-B", str(SCRIPT), "--engine",
                               self.manifest["engine"], "--manifest", str(self.root / "manifest.json")],
                              capture_output=True, text=True, timeout=10)

    def assert_rejected(self, message):
        result = self.run_backtest()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr.lower())
        self.assertNotIn("\"wer\"", result.stdout)

    def test_round_trip_and_read_only_baseline_delta(self):
        first = self.run_backtest()
        self.assertEqual(first.returncode, 0, first.stderr)
        report = json.loads(first.stdout)
        self.assertEqual(report["manifest"], self.manifest)
        self.assertEqual(report["wer"], 0)
        self.assertEqual(report["latency"]["preparationMS"]["p90"], 10)
        baseline = self.root / "baseline.json"
        baseline.write_text(first.stdout)
        before = baseline.read_bytes()
        self.manifest["baselineID"] = "baseline.json"
        second = self.run_backtest()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)["delta"]["wer"], 0)
        self.assertEqual(baseline.read_bytes(), before)

    def test_corrupted_results_json_and_shape(self):
        self.results = {"error": "bad shape"}
        self.assert_rejected("results")
        self.results = [{"fixture": "one.wav", "engine": "SpeechTranscriberEngine",
                         "locale": "en-IN", "audioSHA256": self.digest}]
        self.assert_rejected("transcript")
        self.results = [dict(self.results[0], transcript="hello", audioSHA256="0" * 64)]
        self.assert_rejected("sha256")
        result = self.run_backtest()
        self.assertNotEqual(result.returncode, 0)
        (self.root / "results.json").write_text("{invalid")
        bad = subprocess.run([sys.executable, "-B", str(SCRIPT), "--engine", "apple",
                              "--manifest", str(self.root / "manifest.json")],
                             capture_output=True, text=True, timeout=10)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("json", bad.stderr.lower())
        self.assertNotIn("\"wer\"", bad.stdout)

    def test_swapped_reference_audio_sha_and_corpus_hash(self):
        self.references["utterances"][0]["sha256"] = "0" * 64
        self.assert_rejected("sha256")
        self.references["utterances"][0]["sha256"] = self.digest
        self.references["utterances"][0]["reference"] = "different"
        self.assert_rejected("corpus.sha256")

    def test_empty_audio_bytes_or_zero_duration(self):
        self.audio.write_bytes(b"")
        self.assert_rejected("empty audio")
        self.audio.write_bytes(b"synthetic fixture only")
        self.results[0]["inputDurationMS"] = 0
        self.assert_rejected("duration")
        self.results[0]["inputDurationMS"] = 120
        self.results[0]["durationMS"] = 0
        self.assert_rejected("duration")

    def test_unreachable_cloud_error_or_missing_hypothesis(self):
        self.manifest["engine"] = "sarvam"
        self.manifest["networkType"] = "wifi"
        self.results[0]["engine"] = "sarvam"
        self.results[0]["error"] = "unreachable"
        self.assert_rejected("error")
        del self.results[0]["error"]
        del self.results[0]["transcript"]
        self.assert_rejected("transcript")
        del self.manifest["networkType"]
        self.assert_rejected("networktype")


if __name__ == "__main__":
    unittest.main()
