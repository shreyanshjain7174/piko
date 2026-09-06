# Ideal customer profile

Grounded in Wispr Flow's actual numbers, not guesses — they've spent $280M finding out who pays
for this category. Sources at the bottom.

## The market signal, first

Wispr Flow: $2B valuation, $280M Series B, four straight quarters of 150%+ revenue growth,
125,000+ businesses, 270+ Fortune 500 accounts, 19% free-to-paid conversion (a consumer app
converting like enterprise SaaS), 70–80% year-one retention against a 30–50% consumer-SaaS
norm. This category has demand. The question is only which slice of it Piko can take.

## The wedge Wispr Flow handed us

Wispr Flow is **cloud-only on every platform** — no on-device mode on Mac, Windows, iOS or
Android. Its own FAQ: "Wispr's backend must decrypt audio to perform transcription." Audio is
processed by third-party vendors (Baseten for transcription, OpenAI/Anthropic/Cerebras for
formatting).

That architecture produced a real incident record, not a hypothetical one: a user found it
uploading window screenshots and was banned for reporting it; its SOC 2 was later found to be a
templated fake audit (Delve, 494 nearly-identical reports); a forensic report documented a
system-wide keystroke interceptor and continued uploads even with data-sharing switched off; the
CEO demoed per-user dictation analytics tied to named individuals at named employers; a team
member published word-frequency analysis mined from user dictations. Reviewers now advise
outright: *"If your dictation contains client matters, patient details, unreleased work, or
anything you would not put in a third party's database"* — don't use it — and point to on-device
alternatives instead.

**Piko's entire architecture is the answer to that sentence.** No server exists to decrypt
anything, leak anything, or be queried by a founder in a demo.

## Segments, ranked

### 1. Regulated professionals who dictate confidential information — primary

Lawyers, clinicians, therapists, financial advisors. Wispr Flow already lists these as core
users; its own security page and reviewers simultaneously tell them not to trust it with client
or patient information. That is a paying, proven-willing audience with a documented, public,
unresolved objection.

- **Why they pay:** dictation saves billable time; time is literally priced for this group.
- **Why they pay us specifically:** the privacy claim resolves an objection Wispr Flow cannot
  resolve without rearchitecting itself. We don't have to win on transcription quality alone —
  we start the conversation already having answered their actual blocker.
- **Reach:** professional Slack/Discord communities, legal-tech and health-tech newsletters, a
  direct comparison piece ("why your lawyer shouldn't dictate through the cloud") aimed at the
  exact anxiety the incident list above documents.
- **Risk:** smallest addressable count of the three segments, longest sales cycle even for a
  one-time purchase, and Piko's v0.1 rewriter is not yet tuned for legal/medical terminology —
  that's a real gap, not a marketing problem.

### 2. Mobile AI power users who prompt LLMs by voice — best v0.1 launch cohort

Wispr Flow names this itself as a growth driver: people composing long ChatGPT/Claude prompts
who find typing them out "brutal." This audience is mobile-first, already primed by Wispr Flow's
own virality (512.9M content views cited in its growth story) to want this category, and
overlaps almost exactly with the build-in-public / X audience the `x-growth` skill already
targets.

- **Why they pay:** speed and volume — they dictate a lot, daily, and feel every second of typing
  friction.
- **Why they pay us specifically:** they are the audience for the character and skins — cosmetic,
  shareable, exactly the kind of thing that gets posted. Lower willingness-to-pay per user than
  segment 1, much higher virality and much lower cost to reach.
- **Reach:** this is the TestFlight list. It is also the exact audience the notch-hero demo clip
  and the "I turned on airplane mode and it kept working" post are aimed at.
- **Risk:** the most crowded segment — Superwhisper already ships on-device iOS with contextual
  mode-switching ("iMessage gets casual, email gets professional"), which is close to Piko's
  profile chips. Differentiate on the companion/personalisation layer and on actually being a
  keyboard-first experience, not a feature list.

### 3. India and non-native-English speakers — the market we're already closest to

Wispr Flow calls out India as its **#2 market**, with Hinglish support, ₹320/month local
pricing, and a startling stat: 75% of Indian customers commit annually versus 30–40% globally.
That is a market that has already decided to pay for this category and is under-served by
accent handling in Apple's own dictation.

- **Why they pay:** demonstrated — Wispr Flow's own numbers prove willingness to pay at Indian
  price points, and the annual-commit rate suggests satisfaction once the accent/language
  problem is actually solved.
- **Why they pay us specifically:** proximity — this is the market we're already in, can test in
  ourselves, and can price aggressively for given zero marginal cost.
- **Reach:** the same X audience, skewed toward the home market for the first cohort; regional
  pricing from `docs/MONETISATION.md` was written with exactly this in mind.
- **Risk:** lowest ARPU of the three. Treat as the proving ground and the loudest word-of-mouth
  engine, not the initial revenue thesis.

## Recommendation for v0.1

**Launch cohort = segment 2** (mobile AI power users), for reach and virality, with the
messaging spine borrowed from **segment 1** (the privacy incident record above is more
persuasive copy than anything we could invent). Segment 3 rides along for free — it's the same
channel, same content, just resonates harder at home.

Segment 1 becomes the v0.2 push, once the rewriter has been tuned enough on real edit-pairs to
credibly handle professional terminology, and once there's a retention number to point to rather
than a promise.

## What this changes about the plan

- The landing page's privacy section should cite the incident record above, specifically —
  concrete, sourced, dated claims beat "your data stays private" every time.
- `docs/MODELS.md`'s tier-2 rewriter (Phi-4-mini / SmolLM3) becomes worth prioritising sooner if
  segment 1 is a real near-term target: legal/medical terminology is exactly where Apple's
  general-purpose Foundation Model will underperform a model we can steer.
- Superwhisper's iOS contextual-mode feature is direct prior art for the profile chips in
  `docs/SPEC.md` — worth a hands-on competitive test before finalising that UI, not just a
  feature-parity check.

## Sources

- [Wispr Flow Revenue 2025: $10M Est. ARR, $700M Valuation](https://getlatka.com/companies/wisprflow.ai)
- [How Wispr Flow Grows: 150x Revenue in a Year With Zero Cold Outreach](https://www.postbeam.ai/blog/how-wisprflow-grows)
- [Wispr Flow Valuation: $2B After a $280M Series B in Nine Months](https://valueaddvc.com/blog/wispr-flow-2b-valuation-280m-series-b-ai-dictation-2026)
- [Is Wispr Flow Safe? Seven Incidents and Two Toggles You Need to Know](https://www.getvoibe.com/resources/is-wispr-flow-safe/)
- [Superwhisper — Voice to Text for iOS](https://superwhisper.com/ios)
- [Best Software Tools for Repetitive Strain Injury (RSI) at Work](https://usevoicy.com/blog/best-software-tools-for-rsi)
