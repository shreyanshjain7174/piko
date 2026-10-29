#!/usr/bin/env python3
"""Score paired local recognition results without selecting a shipping engine."""

import argparse
import json
import math
import re
import sys
import unicodedata
from pathlib import Path


def words(text):
    normalized = unicodedata.normalize("NFKC", text).casefold()
    tokens = re.findall(r"[+-]?\d+(?:[.,]\d+)*|\w+(?:['\u2019]\w+)*", normalized)
    return [token.replace("'", "").replace("\u2019", "") for token in tokens]


def edit_counts(reference, hypothesis):
    previous = [(0, 0, index) for index in range(len(hypothesis) + 1)]
    for index, token in enumerate(reference, 1):
        current = [(0, index, 0)]
        for column, other in enumerate(hypothesis, 1):
            substitutions, deletions, insertions = previous[column - 1]
            diagonal = (substitutions + (token != other), deletions, insertions)
            substitutions, deletions, insertions = previous[column]
            deletion = (substitutions, deletions + 1, insertions)
            substitutions, deletions, insertions = current[-1]
            insertion = (substitutions, deletions, insertions + 1)
            current.append(min((diagonal, deletion, insertion), key=sum))
        previous = current
    return previous[-1]


def word_errors(reference, hypothesis):
    return sum(edit_counts(reference, hypothesis))


def latency_summary(reports):
    summary = {}
    for field in ("preparationMS", "firstHypothesisFromFileStartMS", "finalizationMS"):
        values = []
        for report in reports:
            value = report.get(field)
            if value is None:
                continue
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError(f"{field} must be a finite nonnegative millisecond measurement")
            values.append(value)
        values.sort()
        summary[field] = {
            "measured_count": len(values),
            "missing_count": len(reports) - len(values),
            **{f"p{percentile}": values[max(0, math.ceil(len(values) * percentile / 100) - 1)]
               if values else None for percentile in (50, 95, 99)},
        }
    summary["note"] = (
        "File-start to first hypothesis is not speech-onset to keyboard insertion. "
        "Report cold/warm runs and hardware/network conditions separately. "
        "No latency acceptance is inferred."
    )
    return summary


def pair_results(references, apple_results, whisper_results):
    if not isinstance(references, dict) or not isinstance(references.get("utterances"), list):
        raise ValueError("references must contain the frozen utterance list")
    expected = references["utterances"]
    if any(not isinstance(item, dict) or not isinstance(item.get("id"), str)
           or not isinstance(item.get("reference"), str) for item in expected):
        raise ValueError("each frozen reference needs an id and reference string")
    filenames = [item.get("filename") for item in expected]
    if any(not isinstance(name, str) or not name for name in filenames) or len(set(filenames)) != len(filenames):
        raise ValueError("reference filenames must be unique nonempty strings")
    hashes = {}
    for item in expected:
        digest = item.get("sha256")
        if not isinstance(digest, str) or re.fullmatch("[0-9a-f]{64}", digest) is None:
            raise ValueError("each frozen reference needs its actual audio SHA-256")
        hashes[item["filename"]] = digest
    outputs = {}
    platforms = set()
    for label, reports, engine in (
        ("apple", apple_results, "SpeechTranscriberEngine"),
        ("whisper", whisper_results, "WhisperTranscriberEngine"),
    ):
        if not isinstance(reports, list):
            raise ValueError(f"{label} results must be an actual report list")
        mapped = {}
        for report in reports:
            if not isinstance(report, dict) or report.get("engine") != engine:
                raise ValueError(f"{label} report has the wrong engine, including a possible mock")
            name = report.get("fixture")
            if name not in filenames or name in mapped or not isinstance(report.get("transcript"), str):
                raise ValueError(f"{label} results contain missing, duplicate, or unknown fixtures")
            if report.get("locale") != references.get("locale"):
                raise ValueError(f"{label} locale differs from the frozen references")
            if report.get("audioSHA256") != hashes[name]:
                raise ValueError(f"{label} audio differs from the frozen reference bytes")
            platform = report.get("platform")
            if platform not in ("physical", "simulator"):
                raise ValueError(f"{label} report does not identify its actual platform")
            platforms.add(platform)
            mapped[name] = report["transcript"]
        if set(mapped) != set(filenames):
            raise ValueError(f"{label} results are incomplete")
        outputs[label] = mapped
    if len(platforms) != 1:
        raise ValueError("Do not pair physical-device results with Simulator results")
    paired = {
        key: references.get(key) for key in ("corpus_id", "locale", "speaker_count")
    }
    paired["utterances"] = [
        {"id": item["id"], "reference": item["reference"],
         "category": item.get("category", "speech"),
         "apple": outputs["apple"][item["filename"]],
         "whisper": outputs["whisper"][item["filename"]]}
        for item in expected
    ]
    paired["measurement_summary"] = {
        "platform": next(iter(platforms)),
        "audio_identity_verified": True,
        "apple": latency_summary(apple_results),
        "whisper": latency_summary(whisper_results),
    }
    return paired


def score(corpus):
    if not isinstance(corpus, dict):
        raise ValueError("corpus must be a JSON object")
    for key in ("corpus_id", "locale"):
        if not isinstance(corpus.get(key), str) or not corpus[key].strip():
            raise ValueError(f"{key} must identify the frozen corpus and actual locale")
    speakers = corpus.get("speaker_count")
    if type(speakers) is not int or speakers < 1:
        raise ValueError("speaker_count must report the actual positive speaker count")
    cases = corpus.get("utterances")
    if not isinstance(cases, list) or not cases:
        raise ValueError("utterances must be a nonempty list")
    metrics = {engine: {"word_errors": 0, "substitutions": 0, "deletions": 0, "insertions": 0,
                        "reference_words": 0, "silence_hallucinations": 0}
               for engine in ("apple", "whisper")}
    cases_scored = []
    seen = set()
    speech_count = silence_count = 0
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("each utterance must be an object")
        identifier = case.get("id")
        if not isinstance(identifier, str) or not identifier.strip() or identifier in seen:
            raise ValueError("each utterance needs a unique nonempty id")
        seen.add(identifier)
        category = case.get("category", "speech")
        if category not in ("speech", "silence"):
            raise ValueError(f"{identifier}: category must be speech or silence")
        for key in ("reference", "apple", "whisper"):
            if not isinstance(case.get(key), str):
                raise ValueError(f"{identifier}: {key} must contain an actual string result")
        reference = words(case["reference"])
        if category == "speech" and not reference:
            raise ValueError(f"{identifier}: speech reference cannot be empty")
        if category == "silence" and reference:
            raise ValueError(f"{identifier}: silence reference must be empty")
        speech_count += category == "speech"
        silence_count += category == "silence"
        case_metrics = {"id": identifier, "category": category, "reference_words": len(reference)}
        for engine in metrics:
            hypothesis = words(case[engine])
            if max(len(reference), len(hypothesis)) > 1000:
                raise ValueError(f"{identifier}: split long recordings into utterances")
            metrics[engine]["reference_words"] += len(reference)
            if category == "silence":
                metrics[engine]["silence_hallucinations"] += bool(case[engine].strip())
                metrics[engine]["insertions"] += len(hypothesis)
                metrics[engine]["word_errors"] += len(hypothesis)
                case_metrics[engine] = {"word_errors": len(hypothesis), "wer": None}
            else:
                counts = edit_counts(reference, hypothesis)
                metrics[engine]["word_errors"] += sum(counts)
                for key, count in zip(("substitutions", "deletions", "insertions"), counts):
                    metrics[engine][key] += count
                case_metrics[engine] = {
                    "word_errors": sum(counts), "wer": sum(counts) / len(reference)
                }
        cases_scored.append(case_metrics)
    complete = speech_count >= 30 and silence_count > 0
    for item in metrics.values():
        count = item["reference_words"]
        item["wer"] = item["word_errors"] / count if count else None
        item["accuracy_gate_passed"] = (
            complete and count > 0
            and item["word_errors"] * 10 <= count and item["silence_hallucinations"] == 0
        )
    apple, whisper = metrics["apple"], metrics["whisper"]
    candidate = "unverified"
    if complete:
        candidate = "none"
        if apple["accuracy_gate_passed"]:
            candidate = "apple"
        if (whisper["accuracy_gate_passed"] and apple["word_errors"] > 0
                and whisper["word_errors"] * 5 <= apple["word_errors"] * 4):
            candidate = "whisper"
    return {
        "corpus_id": corpus["corpus_id"],
        "locale": corpus["locale"],
        "speaker_count": speakers,
        "speech_cases": speech_count,
        "silence_cases": silence_count,
        "corpus_complete": complete,
        "engines": metrics,
        "utterance_metrics": cases_scored,
        "measurement_summary": corpus.get("measurement_summary"),
        "accuracy_candidate": candidate,
        "shipping_engine": "unverified",
        "device_gates": "unverified",
        "note": "Accuracy only. Device latency, data safety, background/offline survival, "
                "memory and user engine approval remain required.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--apple-results", type=Path)
    parser.add_argument("--whisper-results", type=Path)
    args = parser.parse_args()
    if bool(args.apple_results) != bool(args.whisper_results):
        parser.error("both --apple-results and --whisper-results are required together")
    try:
        with args.corpus.open(encoding="utf-8") as source:
            corpus = json.load(source)
        if args.apple_results:
            with args.apple_results.open(encoding="utf-8") as source:
                apple = json.load(source)
            with args.whisper_results.open(encoding="utf-8") as source:
                whisper = json.load(source)
            corpus = pair_results(corpus, apple, whisper)
        result = score(corpus)
    except (OSError, ValueError, TypeError) as error:
        print(f"Cannot score corpus: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
