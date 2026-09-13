# Experience acceptance spec — MVP

The contract for the MVP experience pass. The coder implements against it; the verifier
agent tests against it and flags violations; the UX agent judges it as a first-time user.
"Pass" means zero open violations at the verifier, and no "would-delete-this-app" findings
from the UX agent.

## Product frame

Piko is a calm on-device voice buddy that lives on the notch. Hold anywhere, speak, tidied
text lands where you were. Nothing leaves the device. The UI must feel like one character
across every surface: Home, History, Settings, Onboarding, the keyboard, and the notch.

## Designer criteria (visual)

- D1. Dark "stage" surfaces (Home, Onboarding, History, Settings) share one background
  language: deep navy gradient, skin-tinted aurora glow, glass cards (`glassEffect` or
  white-opacity layers). No system grouped-table grey on these screens.
- D2. The character (PikoFace) appears on Home, in Settings' skin picker, on the lock
  screen / Island, and on the keyboard mic. The orb is translucent — the character is
  always the subject.
- D3. Motion only communicates state; springs, interruptible; Reduce Motion gets a real
  alternative. No motion for decoration.
- D4. Copy: second person, one line, no exclamation marks in system copy, no emoji in
  transcription surfaces, "suggestions not solutions" tone.
- D5. App icon is a real branded mark (the orb+face), not the blank template.
- D6. No clipped, overlapping, or truncated UI at default Dynamic Type on a 6.1" viewport;
  nothing important under the tab bar or the home indicator.
- D7. Every screen responds visually to phase change (idle / armed / capturing / tidying)
  where phase is visible.

## Verifier criteria (functional + state)

- V1. `make project`, `make test` (SPM), and `xcodebuild build` for iPhone 17 Pro (26.5)
  succeed with zero errors; `PikoUITests` pass.
- V2. Every primary control works when driven by XCUITest: hold-to-talk orb, stop strip,
  session arm/end, copy, clear, tab switching, onboarding open/close, correction sheet
  open/cancel.
- V3. State machine: idle → armed → capturing (orb deforms, wave flows, notch bars dance)
  → tidying (no capture controls active) → result (transcript card, memory line refreshes).
  No stale UI after any transition: phase text, dot color, and button labels must match.
- V4. Fresh-install first run: app opens straight to Home with no crash, no empty-state
  holes; History shows its empty state; Settings shows permissions truthfully.
- V5. History: rows render shipped text + date + profile; search filters; swipe copy and
  delete work; detail opens; correction sheet saves a local edit pair; delete updates list.
- V6. Keyboard extension target links only PikoKit/PikoBridge/PikoUI; builds; MicButton
  reflects phase and uses the wave while capturing.
- V7. `-pikoRealSpeech` on the Simulator routes through SpeechTranscriberEngine so real
  MacBook-microphone audio (spoken via local TTS) is transcribed — the transcript must
  contain the spoken words, not the canned demo script.
- V8. Accessibility: every control has a label; the orb has button trait + activation
  action; Reduce Motion paths compile and are exercised by tests where feasible.
- V9. DEBUG demo hooks never compile into release configurations (guarded by `#if DEBUG`
  / `#if targetEnvironment(simulator)`).

## UX agent criteria (first-person)

- U1. First minute: without docs, a new user understands what to do (the orb invites the
  hold; the keyboard card explains the globe-key path).
- U2. Trust: privacy is visible but not preachy; no cloud glyphs anywhere; copy never
  over-promises.
- U3. Feel: nothing shouts; no notification-ish behavior; motion is smooth, not bouncy
  noise; the assistant reads as a buddy, not a chatbot.
- U4. Every screen looks shipped: no blank icons, no placeholder grey, no clipped text.

## Out of scope (hard)

No external services, accounts, payments, or network calls in the core loop. All
verification happens on this machine (Simulator, local TTS, local test suites).
