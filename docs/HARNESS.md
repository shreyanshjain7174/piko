# Piko's harness — desktop agent engineering, pocket-sized

Desktop coding agents earn their keep with a harness: a router, tools, a planner, a
verifier, and context engineering that keeps the model honest. Piko wants the same
personal-assistant competence, but the desktop harness cannot be ported — a phone has no
persistent daemon (C10), no idle CPU, a mic that only opens in the foreground (C1–C3), and
a user who will delete anything that feels like a chat app. This document defines the
translation.

## The mapping

| Desktop harness | Piko pocket harness | Why |
|---|---|---|
| Long-lived process, hours of runtime | **A turn, not a session**: perceive → route → act → respond → settle (≤ 300 ms warm) | C10 — the harness "sleeps" between invocations; state survives in the graph + App Group, not in RAM |
| Planner decomposes tasks | **Router picks one of three routes** — write / recall / suggest — with a deterministic prefilter | One utterance = one intention, usually. A planner's cost is unjustified below ~5% multi-step traffic (Route enum already exists in PikoKit) |
| 30+ tools, MCP servers | **Five typed tools, no more**: `memory.recall`, `memory.remember`, `memory.forget`, `capture.start/stop`, `rewrite` | Every tool is a schema'd struct so Foundation Models guided generation can drive them later without string parsing |
| Verifier agents re-check output | **Quiet verification**: deterministic checks (recall hit-count > 0, insertion landed, faithfulness budget) + the user as final verifier — every correction is an `EditPair` that retrains the next turn | The loop still closes; it closes through the human, in one tap, not through a second model pass |
| Context stuffing | **`MemoryPacket` is the whole context**: bounded, structured, 8 entities max | Retrieval, never a growing prompt — the on-device window is 8k tokens |
| Logs + dashboards | **The pet is the harness status light**: fresh/happy/calm/sleepy + phase expressions render agent state continuously | Interactivity is the UI, not a dashboard |
| Escalation to bigger models | **The tier ladder**: tier 0 deterministic (free, always) → tier 1 Foundation Models (on-device, when complexity demands) → tier 2 cloud (explicit opt-in, v2+) | Battery is the budget — see MEMORY-ARCHITECTURE.md |

## The turn pipeline

```
utterance (voice or text)
  → ROUTE     deterministic prefilter; ambiguous → write (dictation default)
  → ACT       route's tool: recall() = memory packet; write = capture pipeline;
              suggest = SuggestionEngine over the packet
  → RESPOND   one line + at most two tappable chips; optional soft voice (PikoSpeaker)
  → SETTLE    tier-0 indexing (debounced), mood recompute, edit-pair learning
```

Rules of the turn:

1. **Respond before you compute.** The notch/pet reacts to *state*, the line renders from
   the packet — nothing in the pipeline may block the first paint.
2. **One question mark per turn.** The agent asks at most one clarifying thing, via a
   chip, never a conversation.
3. **Say what you know, not what you guess.** A recall miss renders the honest fallback
   ("Nothing yet — tell me about it and I'll remember."), never a confabulation.
4. **Every turn ends quieter than it began.** No follow-up notifications, no re-engagement.

## Interactivity model (what "more interactive than desktop" means)

- **Voice in, voice out, both optional.** Dictation is the input; `AVSpeechSynthesizer`
  with a cute tuning (pitch 1.32, rate 0.46, volume 0.5, on-device voice) is the output —
  off by default in v1, one toggle in Settings, never speaking while the mic is live.
- **Chips over chat.** Agent output carries tappable continuations ("Forget Mom",
  "Pick it back up") — one tap is a whole follow-up turn, typed or spoken input never
  required.
- **Haptics are acknowledgements**: arm = tick, insert = blip, suggestion tap = soft
  double-tap. The phone talks through your pocket.
- **Memory is the personal feel**: "Last time you said '…'", "You talk about Mom a lot —
  maybe say hi." The graph (MEMORY-ARCHITECTURE.md) is what makes those lines true.

## Tool registry (v1, deterministic tier)

| Tool | Signature | Route |
|---|---|---|
| `memory.recall` | `(query) -> MemoryPacket` | recall |
| `memory.remember` | `(result) -> Void` + tier-0 index | write (settle phase) |
| `memory.forget` | `(entityName) -> Void` | chip on a recall turn |
| `capture.*` | existing armed-session pipeline | write |
| `rewrite` | existing Brain protocol | write |

Tier 1 (Foundation Models) slots in as *another router implementation behind the same
`AgentRouter` protocol* — the harness contract does not change when the intelligence does.

## Non-goals

No conversation transcript UI, no multi-turn chat with the pet, no cloud tools, no
notifications-as-engagement. The assistant is a buddy on the notch with a memory, not a
chat window.
