#!/usr/bin/env python3
"""Report-only hosted-runner probe; no microphone, audio, or model downloads."""
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = pathlib.Path(__file__).with_name("SpeechProbe.swift")
SUMMARY = os.environ.get("GITHUB_STEP_SUMMARY")


def report(stage, line):
    text = f"SPIKE {stage}: {line}"
    print(text, flush=True)
    if SUMMARY:
        with open(SUMMARY, "a", encoding="utf-8") as summary:
            summary.write(text + "\n\n")


def command(args, seconds, cwd=ROOT):
    start = time.monotonic()
    try:
        result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=seconds,
                                errors="replace")
        return result.returncode, result.stdout.strip(), round(time.monotonic() - start, 1)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return 124, output.strip() + f"\nTIMEOUT after {seconds}s", round(time.monotonic() - start, 1)
    except OSError as exc:
        return 127, str(exc), round(time.monotonic() - start, 1)


def details(stage, output, limit=1200):
    for line in output[-limit:].splitlines():
        report(stage, line)


def main():
    report("environment", "runner label=xcode-27 DEVELOPER_DIR=" + os.environ.get("DEVELOPER_DIR", "unset"))
    for name, args in [
        ("macOS", ["sw_vers"]),
        ("Xcode", ["xcodebuild", "-version"]),
        ("CPU", ["uname", "-m"]),
        ("simulator list", ["xcrun", "simctl", "list", "runtimes", "devices", "available"]),
    ]:
        code, output, elapsed = command(args, 40)
        report("environment", f"{name} exit={code} elapsed={elapsed}s")
        details("environment", output, 6000)

    with tempfile.TemporaryDirectory(prefix="speech-runner-") as temp:
        folder = pathlib.Path(temp)
        binary = folder / "SpeechProbe"
        code, output, elapsed = command(["xcrun", "swiftc", "-parse-as-library", "-o", str(binary), str(SOURCE)], 120)
        report("host", f"compile exit={code} elapsed={elapsed}s")
        if code:
            details("host", output)
            report("host", "speech API results=not determined (compile failed)")
        else:
            code, output, elapsed = command([str(binary)], 75)
            report("host", f"execution exit={code} elapsed={elapsed}s")
            details("host", output, 4000)
            if code:
                report("host", "speech API results=not determined (execution failed)")
        report("host", "authorization request=not attempted; non-interactive request behavior not determined")

        code, output, elapsed = command(["xcrun", "simctl", "list", "devices", "available", "-j"], 35)
        device = None
        if code == 0:
            try:
                devices = json.loads(output)["devices"]
                device = next((entry for runtime, entries in devices.items()
                               if "iOS" in runtime for entry in entries
                               if entry.get("isAvailable") and entry.get("udid")), None)
            except (ValueError, KeyError, TypeError) as exc:
                report("simulator", f"device list parse error={exc}")
        else:
            report("simulator", f"device list exit={code}")
            details("simulator", output)
        if not device:
            report("simulator", "boot=not attempted (no available iOS Simulator); speech API results=not determined")
        else:
            udid = device["udid"]
            report("simulator", "selected=" + device.get("name", "unknown") + " udid=" + udid)
            code, output, elapsed = command(["xcrun", "simctl", "boot", udid], 90)
            report("simulator", f"boot exit={code} elapsed={elapsed}s")
            if code:
                details("simulator", output)
                report("simulator", "speech API results=not determined (boot failed)")
            else:
                code, output, elapsed = command(["xcrun", "simctl", "bootstatus", udid, "-b"], 150)
                report("simulator", f"bootstatus exit={code} elapsed={elapsed}s")
                if code:
                    details("simulator", output)
                    report("simulator", "speech API results=not determined (bootstatus failed)")
                else:
                    app = folder / "SpeechRunnerProbe.app"
                    app.mkdir()
                    (app / "Info.plist").write_bytes(plistlib.dumps({
                        "CFBundleIdentifier": "dev.piko.speech-runner-probe",
                        "CFBundleExecutable": "SpeechRunnerProbe",
                        "CFBundleName": "SpeechRunnerProbe",
                        "CFBundlePackageType": "APPL",
                        "CFBundleVersion": "1",
                        "CFBundleShortVersionString": "1.0",
                        "MinimumOSVersion": "26.0",
                        "NSSpeechRecognitionUsageDescription": "Report-only speech availability probe; never requests authorization.",
                    }))
                    sdk_code, sdk, _ = command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], 20)
                    if sdk_code:
                        report("simulator", f"SDK lookup exit={sdk_code}; speech API results=not determined")
                        details("simulator", sdk)
                    else:
                        arch = command(["uname", "-m"], 10)[1]
                        code, output, elapsed = command([
                            "xcrun", "swiftc", "-parse-as-library", "-sdk", sdk,
                            "-target", f"{arch}-apple-ios27.0-simulator",
                            "-o", str(app / "SpeechRunnerProbe"), str(SOURCE),
                        ], 120)
                        report("simulator", f"compile exit={code} elapsed={elapsed}s")
                        if code:
                            details("simulator", output)
                            report("simulator", "speech API results=not determined (compile failed)")
                        else:
                            for name, args, wait in [
                                ("sign", ["codesign", "--force", "--sign", "-", str(app)], 35),
                                ("install", ["xcrun", "simctl", "install", udid, str(app)], 90),
                                ("launch", ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", udid, "dev.piko.speech-runner-probe"], 90),
                            ]:
                                code, output, elapsed = command(args, wait)
                                report("simulator", f"{name} exit={code} elapsed={elapsed}s")
                                details("simulator", output, 4000 if name == "launch" else 1200)
                                if name == "launch" and code == 0 and "authorizationStatus=" not in output:
                                    report("simulator", "speech API results=not determined (no probe output captured)")
                                if code:
                                    report("simulator", f"speech API results=not determined ({name} failed)")
                                    break
            report("simulator", "authorization request=not attempted; non-interactive request behavior not determined")

    report("whisper", "runtime inference=not tested; ~630 MB model not downloaded or staged")
    for name, args, seconds in [
        ("resolve", ["xcodebuild", "-resolvePackageDependencies", "-scheme", "PikoTranscribe"], 480),
        ("iOS Simulator build", ["xcodebuild", "-scheme", "PikoTranscribe", "-destination", "generic/platform=iOS Simulator", "build"], 600),
    ]:
        code, output, elapsed = command(args, seconds)
        report("whisper", f"{name} exit={code} elapsed={elapsed}s")
        if code:
            details("whisper", output, 2500)
        else:
            details("whisper", "\n".join(line for line in output.splitlines()
                                       if "Resolved source packages:" in line or "argmax" in line
                                       or "BUILD SUCCEEDED" in line)[-1200:])
        if code and name == "resolve":
            report("whisper", "iOS Simulator build=not attempted (resolution failed)")
            break
    report("whisper", "runtime execution=not determined (model deliberately absent)")


if __name__ == "__main__":
    main()
