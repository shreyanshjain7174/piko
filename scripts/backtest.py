#!/usr/bin/env python3
# Offline, read-only scoring of frozen single-engine fixture replays.
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys


SCORER_PATH = Path(__file__).with_name("score-transcriptions.py")
spec = importlib.util.spec_from_file_location("transcription_scorer", SCORER_PATH)
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)
TIMINGS = ("preparationMS", "firstHypothesisFromFileStartMS", "finalizationMS")
ENGINES = {"apple": "SpeechTranscriberEngine", "whisper": "WhisperTranscriberEngine"}


def load_json(path, label):
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} JSON is invalid: {error}") from error


def required_text(obj, key, label):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}.{key} must be a nonempty string")
    return value


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def checked_manifest(manifest, engine):
    if not isinstance(manifest, dict) or type(manifest.get("schema")) is not int or manifest["schema"] != 1:
        raise ValueError("manifest.schema must be 1")
    for key in ("engine", "engineVersion", "locale", "device", "iosBuild", "runKind", "references", "results"):
        required_text(manifest, key, "manifest")
    if manifest["engine"] != engine:
        raise ValueError("ENGINE does not match manifest.engine")
    if manifest["runKind"] not in ("cold", "warm"):
        raise ValueError("manifest.runKind must be cold or warm")
    if engine not in ENGINES:
        required_text(manifest, "networkType", "manifest")
    if "baselineID" in manifest:
        required_text(manifest, "baselineID", "manifest")
    corpus = manifest.get("corpus")
    if not isinstance(corpus, dict):
        raise ValueError("manifest.corpus must be an object")
    required_text(corpus, "id", "corpus")
    if not digest(corpus.get("sha256")):
        raise ValueError("corpus.sha256 must be a lowercase SHA-256 digest")
    if corpus.get("split") not in ("baseline", "heldout"):
        raise ValueError("corpus.split must be baseline or heldout")


def resolve_audio(root, filename):
    if not isinstance(filename, str) or not filename or Path(filename).name != filename:
        raise ValueError("reference filename must be a plain filename next to references")
    path = (root / filename).resolve()
    if path.parent != root.resolve():
        raise ValueError(f"reference filename escapes audio directory: {filename}")
    return path


def checked_references(manifest, path):
    references = load_json(path, "references")
    if not isinstance(references, dict) or not isinstance(references.get("utterances"), list) or not references["utterances"]:
        raise ValueError("references must contain a nonempty utterances list")
    if references.get("corpus_id") != manifest["corpus"]["id"] or references.get("locale") != manifest["locale"]:
        raise ValueError("references corpus_id or locale differs from manifest")
    entries = []
    names = set()
    ids = set()
    for item in references["utterances"]:
        if not isinstance(item, dict):
            raise ValueError("each reference utterance must be an object")
        identifier = required_text(item, "id", "reference")
        filename = required_text(item, "filename", "reference")
        if identifier in ids or filename in names:
            raise ValueError("duplicate reference id or filename")
        ids.add(identifier)
        names.add(filename)
        text = item.get("reference")
        if not isinstance(text, str):
            raise ValueError(f"{filename}: reference must be text")
        category = item.get("category", "speech")
        if category not in ("speech", "silence") or (category == "speech" and not scorer.words(text)) or (category == "silence" and scorer.words(text)):
            raise ValueError(f"{filename}: invalid speech/silence reference")
        audio = resolve_audio(path.parent, filename).read_bytes()
        if not audio:
            raise ValueError(f"{filename}: empty audio cannot be scored")
        actual = hashlib.sha256(audio).hexdigest()
        if not digest(item.get("sha256")) or item["sha256"] != actual:
            raise ValueError(f"{filename}: reference audio sha256 does not match file bytes")
        entries.append([filename, actual, text])
    # Canonical UTF-8 JSON of sorted (filename, audio sha256, reference text) triples.
    frozen = json.dumps(sorted(entries), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if hashlib.sha256(frozen).hexdigest() != manifest["corpus"]["sha256"]:
        raise ValueError("corpus.sha256 differs from frozen audio and reference entries")
    return references


def checked_results(manifest, references, path):
    reports = load_json(path, "results")
    if not isinstance(reports, list):
        raise ValueError("results must be a list of reports")
    expected = {item["filename"]: item for item in references["utterances"]}
    mapped = {}
    for report in reports:
        if not isinstance(report, dict):
            raise ValueError("results entry must be an object")
        filename = report.get("fixture")
        if not isinstance(filename, str) or filename not in expected or filename in mapped:
            raise ValueError("results contain unknown, duplicate or missing fixtures")
        if "error" in report:
            raise ValueError(f"{filename}: result error: {report['error']}")
        if report.get("engine") != ENGINES.get(manifest["engine"], manifest["engine"]):
            raise ValueError(f"{filename}: result engine differs from manifest (or is a mock)")
        if report.get("locale") != manifest["locale"]:
            raise ValueError(f"{filename}: result locale differs from manifest")
        if report.get("audioSHA256") != expected[filename]["sha256"]:
            raise ValueError(f"{filename}: results audioSHA256 differs from frozen audio sha256")
        if not isinstance(report.get("transcript"), str):
            raise ValueError(f"{filename}: missing transcript/hypothesis; failure cannot be scored as silence")
        for field in ("inputDurationMS", "durationMS"):
            if field in report:
                value = report[field]
                if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                    raise ValueError(f"{filename}: {field} duration must be positive")
        mapped[filename] = report
    if set(mapped) != set(expected):
        raise ValueError("results are incomplete; missing fixtures cannot be scored")
    return [mapped[item["filename"]] for item in references["utterances"]]


def latency(reports):
    # Reuse the scorer validation and p50/p95; p90 uses the same nearest-rank rule.
    base = scorer.latency_summary(reports)
    summary = {}
    for field in TIMINGS:
        values = sorted(report[field] for report in reports if report.get(field) is not None)
        summary[field] = {key: base[field][key] for key in ("measured_count", "missing_count", "p50", "p95")}
        summary[field]["p90"] = values[math.ceil(len(values) * 0.9) - 1] if values else None
    return summary


def baseline_delta(manifest, report, root):
    baseline = load_json(root / manifest["baselineID"], "baseline")
    if not isinstance(baseline, dict) or not isinstance(baseline.get("manifest"), dict):
        raise ValueError("baseline report must contain a manifest")
    previous = baseline["manifest"]
    if (previous.get("corpus") != manifest["corpus"] or previous.get("locale") != manifest["locale"]
            or previous.get("runKind") != manifest["runKind"]):
        raise ValueError("baseline corpus, locale and runKind must match for deltas")
    try:
        prior_wer = baseline["wer"]
        if type(prior_wer) not in (int, float) or not math.isfinite(prior_wer) or prior_wer < 0:
            raise ValueError("invalid baseline WER")
        delta = {"baselineID": manifest["baselineID"], "wer": report["wer"] - prior_wer, "latency": {}}
        for field in TIMINGS:
            delta["latency"][field] = {}
            for percentile in ("p50", "p90", "p95"):
                now = report["latency"][field][percentile]
                before = baseline["latency"][field][percentile]
                if before is not None and (type(before) not in (int, float) or not math.isfinite(before) or before < 0):
                    raise ValueError("invalid baseline latency")
                delta["latency"][field][percentile] = now - before if now is not None and before is not None else None
    except (KeyError, TypeError) as error:
        raise ValueError(f"invalid baseline report shape: {error}") from error
    return delta


def backtest(manifest_path, engine):
    manifest = load_json(manifest_path, "manifest")
    checked_manifest(manifest, engine)
    root = manifest_path.parent
    references = checked_references(manifest, root / manifest["references"])
    reports = checked_results(manifest, references, root / manifest["results"])
    counts = {key: 0 for key in ("substitutions", "deletions", "insertions", "reference_words")}
    for item, result in zip(references["utterances"], reports):
        reference = scorer.words(item["reference"])
        hypothesis = scorer.words(result["transcript"])
        if max(len(reference), len(hypothesis)) > 1000:
            raise ValueError(f"{item['filename']}: split long recordings into utterances")
        edits = scorer.edit_counts(reference, hypothesis)
        for key, value in zip(("substitutions", "deletions", "insertions"), edits):
            counts[key] += value
        counts["reference_words"] += len(reference)
    if counts["reference_words"] == 0:
        raise ValueError("no speech reference words; WER is undefined")
    report = {"manifest": manifest, "cases": len(reports), "counts": counts,
              "wer": sum(counts[key] for key in ("substitutions", "deletions", "insertions")) / counts["reference_words"],
              "latency": latency(reports),
              "latencyNote": "Nearest-rank p50/p90/p95 of present milliseconds: sorted index ceil(n*p/100)-1; missing measurements are not zero."}
    if "baselineID" in manifest:
        report["delta"] = baseline_delta(manifest, report, root)
    return report


def main():
    parser = argparse.ArgumentParser(description="Offline, read-only single-engine fixture backtest")
    parser.add_argument("--engine", required=True)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = backtest(args.manifest, args.engine)
    except (OSError, ValueError, TypeError) as error:
        print(f"Cannot backtest: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
