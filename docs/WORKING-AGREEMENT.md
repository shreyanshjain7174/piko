# Working agreement

How the humans and the agents on this repo are expected to operate. Short on purpose.

## 1. Options before execution

For anything beyond a trivial edit, do not silently pick the first approach that works. Produce
**two or three real options, at least one of which is non-obvious**, name the trade-off in a
sentence each, recommend one, and say why. Then proceed with the recommendation unless the human
picks differently.

The point is not ceremony. It is that this project keeps hitting OS walls where the obvious path
is blocked and the good path is sideways — the armed session exists because someone refused to
accept "keyboards can't record, therefore no keyboard dictation".

A useful prompt to run against yourself before starting: *what would this look like if the
obvious approach were forbidden?*

## 2. Search before assuming

iOS 27 moved fast and iOS 26 reshuffled the same surfaces just before it — training data lies
about both. Before writing against any Apple framework, check the `apple-docs` MCP server or
current documentation. An invented method signature costs more time than the lookup.

Same for constraints: `docs/CONSTRAINTS.md` is sourced. If you believe an entry is wrong, prove
it on a device and update the row with your evidence. Don't route around it on a hunch.

## 3. Prefer the tool that already exists

Check installed skills and MCP servers before hand-rolling. `docs/TOOLING.md` lists what's
available and when to reach for each. Building a bespoke script for something a skill does
properly is the most common way to waste an afternoon here.

## 4. Report honestly

- A Simulator result is not a device result for memory, background audio, or Live Activity cadence.
  Say which one you ran on.
- A spike with no recorded number did not happen. Write results into `docs/SPIKES.md`.
- If you couldn't verify something, say so in the same breath as the claim.

## 5. Suggest, don't wait

If you notice a better path — a cheaper API, a skill that fits, a marketing angle, a simpler
data model — say it, briefly, even if nobody asked. One line is enough. The cost of an unsolicited
good idea is low; the cost of a silently-taken mediocre path compounds.

## 6. Small, reversible, committed

Work in increments that can be reverted. Commit with a message that says why, not what. Never
commit on `main` directly once there is a `main` worth protecting.
