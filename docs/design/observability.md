# Observability

This document covers listeners, inspection, and the loop guard. It is the companion to
`ir.md` (the DSL front end), `network.md` (the compiled network), and `engine.md` (the
propagation loop the events come from).

Status: implemented, end to end.

---

## 1. Listeners: one callback, emitted in one place

```elixir
@callback handle_event(event, state) :: state
```

Clara's listener protocol has seventeen methods. Calls to them are scattered through every
node implementation. Clara's shape forces this: its nodes call each other, so no single
point sees every event, and each node has to report for itself.

This engine drains a work queue instead, so `Rete.Engine` sees every propagation and every
firing. **The engine emits events there, and nowhere else.** No node knows a listener
exists.

A node produces two things it cannot carry out itself, where they happen. It returns both
as ops for the engine to act on instead:

| op | why the node cannot do it |
|---|---|
| `{:retract_facts, node_id, facts}` | retracting has to go back through the alpha network |
| `{:event, event}` | telling a listener is not a node's business |

That is the whole mechanism. Adding an event is a change in one function.

### Cost when nobody is listening

The engine's `emit` helper takes a **function**, not a term. It returns immediately when
the listener list is empty. So an unobserved session allocates nothing, and calls nothing.
Measurements over a 300-fact session show no difference.

### State

`Rete.Engine.State` holds `listeners: [{module, state}]`. This is a list, not a map, so
the attach order is the event order, and one module can attach twice with different state.
Listener state lives on the session. So a session with listeners is still an immutable
value: no processes, no ETS, no side channel.

### Events

| event | when |
|---|---|
| `{:fire_started, opts}` | `fire_rules/2` begins |
| `{:fire_finished, fired}` | the agenda is empty |
| `{:fact_inserted, fact, origin}` | a fact enters working memory |
| `{:fact_retracted, fact, origin}` | a fact leaves it |
| `{:fact_duplicated, fact}` | an equal fact was present, so nothing propagated |
| `{:propagated, op, node_id, count}` | a node consumed `count` items |
| `{:activation_added, source, token}` | a production's LHS became satisfied |
| `{:activation_removed, source, token}` | a pending activation was cancelled |
| `{:activation_fired, source, token, facts}` | a rule ran |

`source` is `%{node: node_id, rule: {module, name}}`. A listener gets an event and its own
state, and it cannot reach the network. So a bare node id would be an integer with no way
to resolve it. `{module, name}` is already the identity that `Rete.Session.query/3` and
`Rete.Inspect.why_not/2` use.

`source` is a map, not a wider tuple, so a field can be added later without changing the
shape every listener matches on. `{:propagated, ...}` is the exception, and it keeps the
bare id: it fires for every node, and a join has no name.

`origin` is `:asserted` or `{:derived, source}`, using the same map. So a concluded fact
can be attributed to the rule that concluded it. This one distinction lets a listener
reconstruct provenance from events alone, without reading memory.

A listener **must** have a catch-all clause. The engine adds new events as it grows. A
listener that crashed on an unfamiliar event would turn every upgrade into a breaking
change.

Two listeners ship with the engine: `Rete.Listener.Collect`, which records everything and
is the substrate for tests, and `Rete.Listener.Trace`, which prints a readable line per
event, with propagation events behind `verbose: true`.

---

## 2. Inspection

`Rete.Inspect` works on **any** session, with no listener attached, because truth
maintenance already records what it needs. `memory.insertions` is `node_id => token =>
[[facts]]`: "this match at this production inserted these facts". Read backwards, this is
exactly a provenance edge. A token's `:matches` is the ordered list of facts behind it.
`explain/2` just walks these two structures.

Prefer the memory-derived answer wherever one exists. It needs no setup, and it cannot
drift from reality. Listeners add only what memory cannot know: history, ordering, and
activations that fired and were later retracted.

| function | question |
|---|---|
| `explain/2` | why does this fact exist? |
| `fired/2` | which rules have concluded something? |
| `why_not/2` | how far did this rule get? |
| `collection/3` | what did this collection gather? |

### `explain/2` returns a list

Each entry is one **independent support**. A fact concluded by two rules, or by one rule
through two matches, has two supports, and it needs both to go before the fact itself
goes. Reporting only the first support would be exactly the kind of lie that makes
retraction look broken.

### What is translated rather than leaked

* **Marker facts.** A compound negation compiles to a generated helper that inserts a
  marker. The marker must be a real fact, for the negation to match on it. But it is not a
  user conclusion: `Session.facts/1` hides it, and `explain/2` skips it when walking
  supports.
* **The root token.** A rule opening with a negation or collection is anchored on a seeded
  empty token. It is not a matched fact, and it is never presented as one.
* **Generated helpers.** `fired/2` hides them, unless you pass `generated: true`.
  `why_not/2` never suggests them in its "no such rule" error.
* **Collections.** A token records the gathered *list*. `explain/2` expands it into its
  members instead, since that is what the user recognizes.

### Reading `why_not/2`

It reports `:elements` (facts matching this condition alone) and `:tokens` (partial
matches arriving from the left) as separate numbers, plus `:activations` on a terminal. It
deliberately avoids one "matches" number. A root join holds elements and emits tokens
without storing them. A production holds neither. A single column would mean something
different at every node, and it would read as `0` where nothing is actually wrong.

Read it left to right and find the first node where the two disagree:

```
node 9  root_join  :cust   elements=2 tokens=0     two customers matched
node 10 negation   :order  elements=1 tokens=2     both reached here; one order suppressed one
node 11 production         elements=0 tokens=0 activations=1
```

---

## 3. The loop guard

`fire_rules/2` runs to quiescence. It caps cycles only when you ask it to, with
`:max_cycles` — `:infinity` by default. It raises an error when the cap is hit.

A **cycle** is one pass of the fire loop. At the default concurrency, one pass takes one
activation. Above the default, one pass takes one whole activation group. The cap bounds
passes, not activations. So raising `:concurrency` fires the same work in fewer, larger
cycles, instead of consuming the allowance faster. See `engine.md` §11.

**This is opt-in, not on by default** — the same call Clara makes. Its
`clara.tools.loop-detector/with-loop-detection` wraps a session and takes `max-cycles` as
a required argument, with no default anywhere.

A count cannot tell two cases apart. Twelve thousand activations could be four thousand
facts moving through a three-rule chain. It could also be a loop that has gone round
twelve thousand times. So any default is a guess about how much legitimate work is too
much. That guess fails on the session that outgrows it: the engine returns an answer that
is not late, but *wrong*, because it stopped part way through settling.

An uncapped run has the opposite failure. An oscillating ruleset spins with no output,
until something interrupts it.

Between a wrong answer and a visible hang, this engine chooses the hang. It hands the
judgment to the caller, who knows whether they are running a test suite or a batch job.

### Choosing a number

Set `:max_cycles` wherever a hang costs more than a false alarm: a test suite, a request
handler, or the first run of a rule someone just wrote.

The cost of setting it too high is whatever the worst runaway does before it trips. The
worst runaway is a rule that concludes a fact its own left hand side matches. This grows
working memory by one fact per activation, measured at about 3.5 ms and 0.46 MB per
thousand activations:

| `max_cycles` | raises after | heap used |
|---|---|---|
| 10,000 | 35 ms | 0.5 MB |
| 100,000 | 270 ms | 46 MB |
| 500,000 | 1.7 s | 230 MB |

Against that, the cost of setting it too low is a `RuntimeError` on work that was actually
fine. The error tells you to raise the limit, so that mistake announces itself. A hang
does not announce itself.

Clara counts transitions between *activation groups*, not activations. Above
`concurrency: 1`, this engine counts groups too. Clara's signal is better in principle,
but it has a failure mode this engine's count does not. A loop confined to a single
salience level produces no group *transitions* at all. The common runaway — a rule
concluding something its own left hand side matches — sits at one salience level.

What the cap does well is its **message**. Pending activations describe whatever happened
to be queued at the moment it hit — arbitrary, for a loop. The error instead leads with
which rules fired most. That is what identifies the loop:

```
Fired most:
  20x  MyRules.grow

Still pending (5 of 12 activations):
  MyRules.grow %{n: 20}

A rule that concludes something its own left hand side matches on will do this.
```

Both lists are cut to five items. Each one says so, when it cuts something. A silent
truncation would read as the whole story.

This engine does **not** add a configurable action, unlike Clara's `:throw-exception` /
`:standard-out-warning`. Nothing needs it yet. A caller who wants to log and continue can
just catch the error.

---

## 4. Known gaps

* **`why_not/2` follows one parent.** A node reached through a disjunction has several
  parents. The first is enough to show where a chain broke, without turning the output
  into a tree. But a rule whose branches fail differently will show only one of them.
* **`fired/2` is a snapshot, not a history.** It reads truth maintenance, so a rule that
  fired and was later retracted does not appear. Attach `Rete.Listener.Collect`, and read
  `:activation_fired` events for that instead.
* **No "why did this fact *not* get concluded".** `why_not/2` answers that for a named
  rule. Nothing starts from a hypothetical fact and works backwards.
* **`Listener.Collect` grows without bound.** Fine for a test or a debugging session, not
  for a long-lived one.
