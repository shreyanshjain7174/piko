# Monetisation

## The unusual position we're in

Piko's inference costs nothing to run. On-device speech is free, Apple's on-device model is
free, and Private Cloud Compute is free below 2M first-time downloads. Every competitor in this
category — Wispr Flow included — charges a subscription largely to cover cloud inference we
don't have.

That means **we can afford to give away the thing they sell**, and we should. The core loop
being free forever is not a growth tactic, it is the proof of the privacy claim: an app with no
server has nothing to meter.

## What is free, permanently

Arm, speak, cleaned text in any field. All four skins' *default* look. Local history and search.
Airplane-mode operation. No account, no trial, no time limit, no word cap.

Anything that would make a user feel their own voice is being held hostage stays free. This is a
line, not a phase.

## What is paid

**Piko Plus — one-time unlock.**

A subscription is hard to defend when marginal cost is zero, and churn management is a tax an
indie developer pays in attention rather than money. One-time also converts better on impulse
after a good first week.

| Tier | Price (anchor) | What it unlocks |
|---|---|---|
| Free | — | The whole core loop, forever |
| Piko Plus | one-time, ~$25–35 / ₹1,900–2,600 | Unlimited profiles, full edit-learning history, personal lexicon import from Contacts and Calendar, export, all skins, Pebble pairing, own-weights model download |
| Skin packs | ~$3–5 each | Cosmetic only. Never gates function. |
| Pebble | hardware margin, v0.3 | Only if Plus is already converting |

Regional pricing from day one. The Indian tier is not the global tier divided by a rounding
error — set it where it actually converts.

**Rule for deciding what goes behind Plus:** if removing it would make someone distrust the app,
it's free. If it makes a heavy user faster, it's Plus. Edit-learning *works* for free; keeping
more than a rolling window of it is Plus.

## Why skins are the sleeper revenue line

Cosmetic, repeatable, cheap to produce, and they are the reason people screenshot the app. A
character with outfits is a merchandising surface that costs a weekend each and never touches
the core promise. This is the closest thing to recurring revenue we can take without a
subscription.

Seasonal or collaboration skins are legitimate. A skin that unlocks a *feature* is not.

## The funnel that already exists

The engineering research behind this app — the iOS constraint ledger, the armed-session
workaround, the "keyboard extensions cannot open the microphone" finding — is genuinely scarce
material. It doubles as the top of the funnel.

1. Publish the constraints write-up as build-in-public content (the `x-growth` skill covers the
   channel work for @shrey_sancheti).
2. That audience is exactly the group who installs a privacy-first dictation app on day one.
3. TestFlight list → launch day volume → App Store ranking → organic.

Treat the research as a product asset, not as spent effort.

## Metrics that actually predict revenue

Vanity metrics here are downloads and DAU. The ones that matter:

- **Arms per day per active user.** Below one, the product hasn't landed. Above three, they'll pay.
- **Edit rate over time.** If corrections per dictation aren't falling week over week, the
  learning loop isn't working and Plus has nothing to sell.
- **D7 retention among users who armed at least twice.** Splits "tried it" from "adopted it".
- **Time from install to first successful dictation in a third-party app.** Every second here is
  conversion.

Measure these on-device and report them in aggregate only if we ever add telemetry at all — and
adding any telemetry is a decision that has to survive the privacy claim, not sneak past it. The
`product-tracking-skills` plugin can design that plan properly when the time comes; do not
sprinkle events by hand.

## What we will not do

- No ads. Ever. An ad-supported app that hears your voice is a different, worse product.
- No selling, sharing, or "anonymised" export of transcripts. There is no server; keep it that way.
- No free trial that expires. The free tier is the trial.
- No paywall in front of the microphone.
