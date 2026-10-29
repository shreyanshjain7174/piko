import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "scorer", Path(__file__).resolve().parents[1] / "score-transcriptions.py")
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


class TranscriptionScoreTests(unittest.TestCase):
    def reports(self, engine, platform="simulator"):
        return [{"fixture": "one.wav", "engine": engine, "locale": "en-IN",
                 "platform": platform, "audioSHA256": "a" * 64, "transcript": "hello"}]

    def test_actual_reports_pair_only_matching_engine_locale_and_platform(self):
        references = {"corpus_id": "unit", "locale": "en-IN", "speaker_count": 1,
                      "utterances": [{"id": "one", "filename": "one.wav",
                                      "sha256": "a" * 64, "reference": "hello"}]}
        apple = self.reports("SpeechTranscriberEngine")
        whisper = self.reports("WhisperTranscriberEngine")
        paired = scorer.pair_results(references, apple, whisper)
        self.assertEqual(paired["utterances"][0]["apple"], "hello")
        with self.assertRaises(ValueError):
            scorer.pair_results(references, apple, self.reports("MockTranscriber"))
        with self.assertRaises(ValueError):
            scorer.pair_results(references, apple, self.reports("WhisperTranscriberEngine", "physical"))
        with self.assertRaises(ValueError):
            scorer.pair_results(references, [], whisper)
        whisper[0]["audioSHA256"] = "b" * 64
        with self.assertRaises(ValueError):
            scorer.pair_results(references, apple, whisper)
        del references["utterances"][0]["filename"]
        with self.assertRaises(ValueError):
            scorer.pair_results(references, apple, whisper)

    def corpus(self, apple="call aarav at 4", whisper="call aarav at 4", count=30):
        cases = [
            {"id": str(index), "reference": "call aarav at 4",
             "apple": apple, "whisper": whisper}
            for index in range(count)
        ]
        cases.append({"id": "silence", "category": "silence",
                      "reference": "", "apple": "", "whisper": ""})
        return {"corpus_id": "unit-fixture-not-device-proof", "locale": "en-IN",
                "speaker_count": 1, "utterances": cases}

    def test_distance_counts_replacements_deletions_and_insertions(self):
        self.assertEqual(scorer.word_errors(["a", "b"], ["a", "c"]), 1)
        self.assertEqual(scorer.word_errors(["a", "b"], []), 2)
        self.assertEqual(scorer.word_errors([], ["a", "b"]), 2)
        self.assertEqual(scorer.edit_counts(["a", "b"], ["a", "c"]), (1, 0, 0))
        self.assertEqual(scorer.edit_counts(["a", "b"], []), (0, 2, 0))
        self.assertEqual(scorer.edit_counts([], ["a", "b"]), (0, 0, 2))

    def test_percentiles_keep_missing_measurements_visible(self):
        reports = [{"preparationMS": value} for value in (10, 20, 30, 100)] + [{}]
        summary = scorer.latency_summary(reports)
        self.assertEqual(summary["preparationMS"]["p50"], 20)
        self.assertEqual(summary["preparationMS"]["p95"], 100)
        self.assertEqual(summary["preparationMS"]["missing_count"], 1)
        self.assertIsNone(summary["finalizationMS"]["p95"])
        with self.assertRaises(ValueError):
            scorer.latency_summary([{"preparationMS": float("nan")}])
        with self.assertRaises(ValueError):
            scorer.latency_summary([{"preparationMS": -1}])

    def test_normalizer_preserves_names_and_numbers(self):
        self.assertEqual(scorer.words("Call AARAV at 4!"), ["call", "aarav", "at", "4"])
        self.assertNotEqual(scorer.words("four"), scorer.words("4"))
        self.assertNotEqual(scorer.words("3.14"), scorer.words("314"))
        self.assertNotEqual(scorer.words("-3"), scorer.words("3"))
        self.assertEqual(scorer.words("Don't call"), ["dont", "call"])

    def test_zero_error_tie_favors_apple_without_shipping_approval(self):
        result = scorer.score(self.corpus())
        self.assertEqual(result["accuracy_candidate"], "apple")
        self.assertEqual(result["shipping_engine"], "unverified")
        self.assertEqual(result["device_gates"], "unverified")

    def test_whisper_quality_advantage_is_not_a_deployment_pass(self):
        result = scorer.score(self.corpus(apple="call someone at 4"))
        self.assertEqual(result["accuracy_candidate"], "whisper")
        self.assertEqual(result["shipping_engine"], "unverified")

    def test_exact_twenty_percent_boundary_uses_integer_error_counts(self):
        corpus = self.corpus()
        for case in corpus["utterances"][:30]:
            case.update(reference="a", apple="a", whisper="a")
        corpus["utterances"][0].update(
            reference=" ".join(["a"] * 48),
            apple=" ".join(["x"] * 5 + ["a"] * 43),
            whisper=" ".join(["x"] * 4 + ["a"] * 44),
        )
        result = scorer.score(corpus)
        self.assertEqual(result["engines"]["apple"]["reference_words"], 77)
        self.assertEqual(result["accuracy_candidate"], "whisper")

    def test_silence_hallucination_fails_engine(self):
        corpus = self.corpus()
        corpus["utterances"][-1]["whisper"] = "thank you"
        result = scorer.score(corpus)
        self.assertFalse(result["engines"]["whisper"]["accuracy_gate_passed"])
        self.assertEqual(result["engines"]["whisper"]["insertions"], 2)
        self.assertEqual(result["engines"]["whisper"]["word_errors"], 2)
        self.assertEqual(result["engines"]["whisper"]["wer"], 2 / 120)

    def test_punctuation_only_silence_is_still_fabricated_text(self):
        corpus = self.corpus()
        corpus["utterances"][-1]["whisper"] = "..."
        result = scorer.score(corpus)
        self.assertFalse(result["engines"]["whisper"]["accuracy_gate_passed"])

    def test_incomplete_corpus_cannot_select_candidate(self):
        self.assertEqual(scorer.score(self.corpus(count=1))["accuracy_candidate"], "unverified")

    def test_missing_result_and_duplicate_ids_are_errors(self):
        corpus = self.corpus()
        del corpus["utterances"][0]["whisper"]
        with self.assertRaises(ValueError):
            scorer.score(corpus)
        corpus = self.corpus()
        corpus["utterances"][1]["id"] = "0"
        with self.assertRaises(ValueError):
            scorer.score(corpus)


if __name__ == "__main__":
    unittest.main()
