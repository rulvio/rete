# W5 — Observability: listeners, loop detection, inspection

**Read [`_context.md`](_context.md) first.** It has the project briefing, the locked design
decisions, the file map and the testing lessons. Everything below assumes it.

**Prerequisite:** [W4](w4-semantic-gaps.md), but only if W4 changes collection grouping — the
inspection output describes collections, so settle their semantics first. If W4 concluded
"document, don't change", you can start here immediately.

---

## Why this phase exists

The engine works but is opaque. When a rule does not fire, or a fact appears that should not
exist, there is currently nothing to ask. This phase makes a session explain itself.

The user selected three items for this phase and deferred async/parallel firing and durability
indefinitely:

1. **Listener hooks** — pluggable observation of every network event.
2. **Loop detection** — a cap on runaway rulesets with a useful error.
3. **Session inspection and explanations** — which rules fired, and why a fact exists.

They are ordered by dependency: inspection is built on listeners, and loop detection is a
listener in Clara's design (though see below — it may not need to be here).

---

## The architectural advantage you are inheriting

Clara's listener protocol has **seventeen methods**, and calls to them are scattered through
every node implementation (`right-activate!`, `left-retract!`, `add-accum-reduced!`, and so on).
That is a direct consequence of Clara's nodes calling each other: there is no single place
events pass through, so every node has to report for itself.

This engine does not work that way. `lib/rete/engine.ex` runs a flat loop over a work queue, and
every propagation passes through `drain/1` and `Rete.Engine.Nodes.handle/2`. **There is exactly
one place events need to be emitted.** `lib/rete/engine/nodes.ex` should not need to change at
all, and if you find yourself adding emit calls inside node clauses, stop and reconsider — you
are rebuilding Clara's shape.

This was an explicit design goal recorded in `lib/rete/engine/state.ex`. Preserve it.

---

## Part 1 — Listeners

### The design

One behaviour, one callback, tagged-tuple events:

```elixir
defmodule Rete.Listener do
  @callback handle_event(event, state) :: state
end
```

Not seventeen callbacks. A listener that cares about one event pattern-matches it and lets the
rest fall through, which is idiomatic Elixir and means adding an event later does not break
every existing listener.

Events worth emitting (map from Clara's `listener.clj` protocol, but consolidate):

```elixir
{:propagate, op_kind, node_id, items}   # :left | :left_retract | :right | :right_retract
{:activation_added, node_id, token}
{:activation_removed, node_id, token}
{:activation_fired, node_id, token, inserted_facts}
{:fact_inserted, fact, :asserted | {:derived, node_id}}
{:fact_retracted, fact, :asserted | {:derived, node_id}}
{:fire_started, opts}
{:fire_finished, activation_count}
```

Design points to settle and document:

- **Where the state lives.** A listener is stateful (a tracer accumulates a trace). Put
  `listeners: [{module, state}]` on `Rete.Engine.State`, fold each event through them, and
  expose the accumulated state via the session. A session must stay an immutable value, so
  listener state is part of it — no processes, no ETS, no agents.
- **Cost when nobody is listening.** The overwhelmingly common case is zero listeners. Make
  that path free: guard on the list being empty before constructing the event term, so no
  garbage is produced. Measure it — the suite should not slow measurably.
- **Attaching.** `Rete.Session.with_listener(session, module, init_state)` and
  `Rete.Session.listener_state(session, module)`, or something better if you see one.

Ship at least two listeners so the behaviour is exercised by more than one shape:

- `Rete.Listener.Collect` — accumulates every event; the substrate for inspection and tests.
- `Rete.Listener.Trace` — human-readable log, Clara's `tracing.clj` is the reference for what
  is worth printing.

### Reference

`clara-rules/src/main/clojure/clara/rules/listener.clj` (183 lines) for the event vocabulary —
note how much of its bulk is the `NullListener` and `DelegatingListener` boilerplate that one
callback and a list make unnecessary. `clara/tools/tracing.clj` (175 lines) for the tracer.

---

## Part 2 — Loop detection

**A cap already exists.** `Rete.Engine.fire_rules/2` takes `:max_cycles` (default 10,000) and
raises a `RuntimeError` naming the pending activations when it is hit. There are tests, and a
W3 review found and fixed an off-by-one in it.

So the question for this phase is whether that is *enough*, and it may well be. Consider:

- The current cap counts activations fired in one `fire_rules/2` call. Clara instead counts
  **transitions between activation groups** (`loop_detector.clj`), which is a different and
  arguably better signal: a rule set that legitimately fires 50,000 activations in one settling
  pass is fine, whereas one that oscillates between two salience levels forever is not. A
  workload that trips the current cap legitimately would have to raise it and thereby lose all
  protection.
- The error message currently lists up to five pending activations. Would a *cycle* — the
  specific loop of rules re-triggering each other — be more useful? A listener that records
  `{:activation_fired, ...}` can detect a repeating sequence.
- Clara lets the caller choose the action (`:throw-exception`, `:standard-out-warning`, or a
  custom function). Worth having? An engine embedded in a server might prefer to log and
  continue rather than raise.

Decide deliberately, and if the answer is "the existing cap is sufficient", write that down in
the design doc with the reasoning rather than silently doing nothing.

Do add a test for the case that is easy to get wrong: **a rule set that fires a lot and then
settles must not raise.** Only genuine non-termination should. (W3's review found the boundary
off by one, so this is not hypothetical.)

---

## Part 3 — Inspection and explanations

The valuable part, and the reason listeners come first.

### What to build

`Rete.Inspect`, answering questions a user actually has:

- **Why does this fact exist?** Given a derived fact, the rule that concluded it and the facts
  its match rested on — recursively, down to the facts the user asserted. This is the headline
  feature.
- **What did this rule do?** Every activation of a rule, with its bindings and what it inserted.
- **Why did this rule *not* fire?** Much harder and much more useful. At minimum: which of its
  conditions have matching facts and which do not, so a user can see where the chain broke.
  Consider reporting the deepest beta node that has tokens.
- **What is in the collection behind this token?** The facts an accumulate node gathered. Clara
  exposes this as `token->matching-elements` (`IAccumInspect` in `engine.clj`) precisely because
  a collection propagates only its result, not its members.

### Where the data comes from

Two sources, and you should use both:

- **Memory, already present.** `memory.insertions` is `node_id => token => [[facts]]` — the
  truth-maintenance record — which is exactly a provenance edge: *this token at this production
  inserted these facts*. A token's `:matches` is `[{fact, node_id}]`, so the facts behind a match
  are already recorded in order. A large part of "why does this fact exist" is a graph walk over
  data the engine already keeps, with **no listener required**. Start here.
- **Listeners**, for anything historical — activations that fired and were later retracted, the
  order things happened, rules that fired during a `fire_rules/2` that is now over.

Prefer the memory-derived answers where possible: they work on any session, with no setup, and
cannot drift from reality.

### Watch out for

- **Marker facts.** Extracted compound negations insert internal marker facts named after
  generated rules. `Rete.Session.facts/1` filters them via `Rete.Network.marker?/2`. Inspection
  output must not leak them either — but an *explanation* may legitimately need to say "this is
  suppressed because a negated conjunction matched", so translate rather than merely hide.
- **The root token.** A rule whose first condition is a negation or collection hangs off a
  seeded empty token (`Rete.Engine.Nodes.seed_root/1`). Do not present it as a matched fact.
- **Generated productions.** `Rete.Compiler.Negation.generated?/1` distinguishes them. A user
  asking "which rules fired" does not want to see `MyMod.clean__neg_1`.

### Reference

`clara/tools/inspect.clj` (456 lines) — `to-explanations`, `get-condition-matches`,
`explain-activation`, `gen-fact->explanations`, `get-root-facts`. `clara/tools/fact_graph.clj`
(96 lines) builds fact provenance as a graph, which is close to what you want and small enough
to read in full.

---

## Definition of done

- A listener can observe a full session lifecycle through one callback, and the zero-listener
  path costs nothing measurable.
- `Rete.Inspect.explain(session, fact)` returns the rule and the supporting facts, recursively
  to asserted facts, for every derived fact in a session using joins, negation, a collection and
  a compound negation.
- Something useful is answerable for a rule that did *not* fire.
- Loop detection is either improved or explicitly documented as sufficient, with reasoning.
- `docs/design/w5-observability.md` written: the event vocabulary, the listener contract, what
  inspection can and cannot answer, and why events are emitted in the loop rather than in nodes.
- `mix test`, `mix compile --force --warnings-as-errors`, `mix format --check-formatted` clean.

## A warning specific to this phase

Inspection tests are unusually easy to write vacuously — asserting that a map has a key, or that
a list is non-empty, proves nothing about whether the explanation is *correct*. Assert on the
actual content: this fact, concluded by that named rule, from those specific supporting facts.
And build a case where the naive answer is wrong — a fact with two independent supports, or one
whose support chain is three deep — so the test can distinguish a real graph walk from a lucky
lookup.

Re-read the testing section of `_context.md` before you start. On this project a green suite has
three times turned out to be hiding real bugs.
