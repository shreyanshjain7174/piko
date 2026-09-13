---
name: piko-ui-craft
description: Piko's product and interface rules — calm Dynamic Island presence, hold-to-talk interactions, suggestion-not-solution copy, Liquid Glass styling, and privacy you can see. Use whenever building, designing, or reviewing any Piko surface — app screens, keyboard UI, Live Activity or Dynamic Island layouts, widgets, onboarding, settings, or the Piko character — even if the user just says "tweak the UI", "add a screen", or "make it nicer".
---

# Piko UI craft

Piko is a calm buddy who lives on the notch, not an assistant that performs. Every visual
decision either serves that or betrays it. The product thesis: **hold a button anywhere, speak,
clean text lands where you were; and nothing ever leaves the device.** A UI that shouts, pings,
or adds steps is working against the product.

## Presence — quiet by default

The Live Activity / Dynamic Island is Piko's "home". Rules:

- **Compact is the resting state.** Compact leading/trailing views show at most one glyph and one
  state cue. If it needs a second look to understand, redesign it.
- **Never pulse, badge, or expand uninvited.** Piko does not seek attention; it answers it.
  Motion in the Island only when state genuinely changed (armed → listening → done).
- **One glance, one answer:** arm, listening level, done. Three states, three looks. No menus in
  the Island — deep actions belong in the app or via the expanded State elsewhere.
- Constraints you must respect (see `docs/CONSTRAINTS.md` C5/C6): the Live Activity can only
  start in the foreground at arm time, and lives 8 h active + 4 h stale. Design the stale/ended
  states on purpose — a dead Island should look asleep, not broken.

## Interaction — hold to talk

- The primary gesture is **press-and-hold, interruptible at any moment**. Release inserts; the
  release point is the promise, so cancellation must feel instant, not animated-out.
- Every entry point does the same thing: keyboard accessory button, Action Button, Control
  Center, user-defined Shortcut, tapping the Island. One gesture, one muscle memory.
- Target the smallest possible time from release to inserted text. Perceived latency hides in
  animations — never animate between the user finishing speaking and text landing.
- Offer a visible stop/cancel affordance the moment listening starts. A listener that cannot be
  interrupted feels like surveillance.

## Motion — state, not decoration

- Springs, not easing curves; interruptible, never restart a transition to animate a change.
  Load the `swiftui-animation` skill for the patterns and `swiftui-liquid-glass` for iOS 26
  material treatment.
- Animate to *explain*: waveform = listening, collapse = done, expand = showing you something.
  If a motion communicates no state, cut it.
- Respect Reduced Motion with a real alternative (opacity/blink on state), not by deleting the
  feedback.

## Copy — a buddy, not a bot

Piko makes **suggestions, not solutions**. The user's words: "I don't want a solution, just a
suggestion." Copy rules:

- Second person, plain words, one line. No exclamation marks in system copy. No emoji in
  transcription surfaces.
- Good: "Dinner you liked last Tuesday is close by." Bad: "🎉 You won't BELIEVE what's nearby!"
- For mood moments, Piko reflects what it noticed, then offers one next step — never a list, never
  a plan. ("You mentioned wanting air. The park you walked in April is 10 minutes away.")
- Interface microcopy: read the `writing-for-interfaces` skill before writing any user-facing
  string set.
- Faithfulness rule applies to UI too: never paraphrase the user's dictated text in the preview —
  show what will land.

## Privacy you can see

- **No cloud glyphs, no sync icons, no upload spinners — anywhere, ever.** If a screen tempts
  you to draw a cloud, the design is wrong.
- Onboarding says it in one line: "Nothing leaves this iPhone. Airplane mode works."
- Corrections the model learns from are shown and editable — learning in secret is not trust.
- Settings labels match mental models ("Learns from your fixes"), not implementation ("Fine-tune
  dataset").

## Haptics — mapped to state, then silent

Arm = one soft tick. Insert = one short success blip. Error = single gentle thud. Never
continuous, never celebratory. The user should feel the state machine with the phone in a pocket.

## Before you call any Piko UI done

Run this checklist — every "no" is a finding:

1. Can it be understood in one glance from the notch?
2. Does it add a step, a sound, or a notification that wasn't asked for?
3. Does the motion communicate state, and is it interruptible?
4. Is there a cloud, badge, or exclamation mark to remove?
5. Would this still make sense with the phone in airplane mode?
6. Did you run it past the accessibility rules (load `ios-accessibility`) and the constraints in
   `docs/CONSTRAINTS.md`?

## Depth on demand

- Dynamic Island / Live Activity specifics → `activitykit` skill, then `docs/ARCHITECTURE.md`.
- Gestures and the hold interaction → `swiftui-gestures`.
- Screen construction and layout → `swiftui-pro`, `swiftui-ui-patterns`.
- Tone and strings → `writing-for-interfaces`; component audit → `swiftui-view-refactor`.
