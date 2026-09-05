# Keyboard voice visualization

The iOS 26 keyboard remains a SwiftUI view inside `UIInputViewController`. The app's
existing `SessionCoordinator` owns AVAudioSession / AVAudioEngine; `CaptureCoordinator`
and `SpeechTranscriberEngine` retain their existing transcription path. No new package
dependency or audio import is added to the keyboard target.

`AudioLevelMonitor.start()` attaches a bounded scalar mailbox to the existing input tap.
The tap calculates RMS over the valid Float32 frames and all channels, respecting
interleaved stride. The monitor converts RMS to dBFS, gates noise, normalizes, smooths,
and publishes a 0–1 level. It never consumes the transcription stream or opens a second mic.
Stop, disarm, and engine-start failure cancel monitoring and publish zero.

Initial tuning (requires physical-microphone validation):

| Parameter | Value |
| --- | --- |
| Gate opens / closes | −48 / −52 dBFS |
| Normalized range | −52 to −12 dBFS |
| Attack / release time constants | 45 / 240 ms |
| Maximum App Group publication rate | 20 Hz |
| Local interpolation time constant | 55 ms |
| Missing-level grace / decay time constant | 150 / 180 ms |
| Drawing schedule | Up to 30 fps; 10 fps color updates with Reduce Motion |

`AudioLevelChannel` is a separate optional protocol. `DarwinChannel` writes a small
atomic `audio-level.json` payload and posts `audioLevelUpdated`, leaving durable session,
draft, and result files independent. Timestamps reject stale and duplicate samples.
Only `VoiceActivityModel` and the wave observe the fast updates, avoiding root-view rebuilds
and keyboard height calculations. A visible-only 250 ms poll recovers missed notifications
and checks heartbeat freshness. Text delivery retains its existing observer lifetime.

`VoiceWave` draws three overlapping ribbons across the keyboard with shared voice energy.
Speech changes their height, thickness, and light intensity; quiet capture settles into
a gently moving baseline. The ends taper smoothly into the keyboard surface.
There are no independent bars, random frame-to-frame shape changes, image assets, or blur
surfaces. Reduce Motion fixes the geometry and changes only intensity. Hidden/background
views pause drawing; expired levels decay to rest; leaving capture clears the model.
The stop symbol stays fixed beside the wave; the entire wave panel is a stop target.

API references checked against Apple's documentation:
[PCM sample pointers and stride](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/floatchanneldata),
[TimelineView](https://developer.apple.com/documentation/swiftui/timelineview), and
[animation scheduling](https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)).

## Verification

Automated tests cover planar/interleaved stereo RMS, valid-frame bounds, silence and
nonfinite samples, gate hysteresis, attack/release, rapid volume changes, buffer cadence,
stop/restart, scalar serialization, isolated bridge file round trips, continuous UI
interpolation, duplicate/stale samples, and capture exit.

Physical-device checks remain required: quiet/noisy room and Bluetooth mic tuning,
foreground-to-background recording, interruption/re-arm, quick keyboard switching,
portrait/landscape and large Dynamic Type, light/dark appearance and Reduce Motion,
end-to-end visual latency, energy use, and peak extension memory below the ~60 MB ceiling.
The existing Simulator path supplies silent PCM and mock transcription; it cannot prove
microphone reactivity or background audio. Simulated energy is for previews/tests only.
