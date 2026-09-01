# Brainstorm: Personal Intelligence / Data Monetization Direction

**Status:** Exploratory only. Not adopted into `.planning/PROJECT.md`'s "Out of Scope" or
`REQUIREMENTS.md`. Does not change v0.1/v0.2 scope, which stays zero-network, on-device-only,
as already committed. Any adoption of this direction is a distinct future milestone decision.

## The idea, as stated

Use transcription (and usage metrics) to build a personal-intelligence layer for the user,
usable for other features later. Storage choice:
- **Local** (on-device, current architecture): free, private, no server.
- **Cloud** (opt-in): paid tier — user is charged for the storage/sync convenience.

Revenue framed as 2–3 sources:
1. Cloud storage/sync subscription.
2. Ad-based monetization, personalizing ads using the personal-intelligence layer.
3. (Implicit) whatever paid tier gates dictation/rewrite features themselves.

Data-ownership framing: the data belongs to the user, not Piko — Piko obtains consent to use it
on the user's behalf (for ads/personalization), rather than claiming ownership.

## Why this needs to be a deliberate, separate decision — not a doc edit

### 1. It directly contradicts the current product's stated identity
`PROJECT.md`'s "Out of Scope" list, written at project start, says explicitly: **"Accounts,
sync, subscriptions, any server at all — zero network dependency is the point."** `REQUIREMENTS.md`'s
Core Value: **"...entirely on-device."** The whole competitive pitch this session (vs. Handy,
vs. "Apple Intelligence routes to ChatGPT") has been "private, on-device, no cloud." An ad-funded
cloud tier is not a small addition to that pitch — it's close to the opposite of it. Both
positionings can coexist (local-only free tier + optional paid cloud tier), but only if that's
designed and communicated as a deliberate two-tier product, not folded into the existing "v0.1 is
zero-network" language.

### 2. Apple App Store policy risk is real and specific, not generic
Piko ships a **custom keyboard extension with Full Access** — this is the single most
policy-scrutinized surface Apple has for third-party apps, specifically because keyboards can see
everything a user types. Apple's App Store Review Guideline 5.1.2 (Data Use and Sharing) requires
explicit disclosure and consent before transmitting keyboard input off-device, and using dictated
content for **ad targeting** specifically is a well-known rejection/pull pattern for third-party
keyboards historically (this is not a hypothetical — it has actually happened to shipped keyboard
apps). Dictated text can trivially contain passwords, health information, financial details,
private messages — treating it as ad-targeting fuel is a materially higher-risk category than
typical app analytics.

### 3. App Tracking Transparency (ATT) applies
If any data is used to serve or measure ads across apps/companies, Apple requires the ATT prompt
(`AppTrackingTransparency` framework). Opt-in rates for ATT are typically 20–40% at best — most
users decline. Any monetization plan assuming broad ad-targeting reach should size itself against
that real ceiling, not against "most users will consent."

### 4. GDPR/CCPA consent is a specific mechanism, not a checkbox
"We can take consent on how to use it for them" needs to become: a specific, informed, granular,
revocable opt-in flow (not bundled into a blanket ToS acceptance), a lawful basis for each
processing purpose (storage vs. personalization vs. ad-targeting are different purposes needing
separate consent under GDPR), a data processing record, and a working deletion/export mechanism.
This is real, non-trivial engineering and legal work, not a documentation change.

## A workable shape, if this direction is pursued later

- **Default tier stays exactly what's built today**: local-only, zero network, free. This
  preserves the existing pitch and avoids the App Store keyboard-data risk entirely for users who
  don't opt in.
- **Cloud tier is a separate, explicit, opt-in product surface** — not a silent backend added to
  the existing local `PikoMemory`/`SQLiteMemory`. Sync would need its own consent screen, its own
  clearly-scoped data-use disclosure, and ideally should NOT be bundled with ad-personalization
  consent (keep "pay for cloud sync" and "consent to ad use of your data" as two separate
  decisions the user makes independently — bundling them is itself a common dark-pattern/GDPR
  compliance risk).
- **Ad-personalization, if pursued at all, is the highest-risk piece** given the keyboard-extension
  context specifically. Worth researching whether a narrower "personalization without ad-network
  sharing" (e.g. sponsored suggestions Piko itself serves, no third-party ad SDK, no ATT trigger)
  gets most of the revenue benefit with much less policy exposure, before committing to full
  ad-network integration.
- **Sequencing**: this is realistically a v0.3+/post-MVP milestone, after the on-device loop
  (v0.1/v0.2, already built) is proven and adopted — not something to fold into current scope.

## Open questions for a real decision (not answered here)

- What specifically is the "personal intelligence" data model — raw transcripts, extracted
  entities/preferences, or something else? Each has a different privacy/retention profile.
- Who is the ad buyer/network integration partner, and what data do they actually receive?
- What does "consent" concretely look like in the UI, and can it be as granular as GDPR needs?
- Does bundling dictation (a sensitive-input surface) with ad monetization undermine the trust
  the "private dictation" pitch is built on, even for users who never opt into cloud/ads?
