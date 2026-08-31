# Observability

Listeners, inspection and the loop guard. The companion to `ir.md` (the DSL
front end), `network.md` (the compiled network) and `engine.md` (the
propagation loop the events are emitted from).

Status: implemented, end to end.

---

## 1. Listeners: one callback, emitted in one place

```elixir
@callback handle_event(event, state) :: state
```

Clara's listener protocol has seventeen methods, and calls to them are scattered
through every node implementation. That is forced by Clara's shape: its nodes
call each other, so there is no single point every event passes through and each
node has to report for itself.

This engine drains a work queue, so `Rete.Engine` sees every propagation and
every firing. **Events are emitted there and nowhere else.** No node knows a
listener exists.

Two things a node produces cannot be carried out where they happen, and both are
returned as ops for the engine to act on:

| op | why the node cannot do it |
|---|---|
| `{:retract_facts, node_id, facts}` | retracting has to go back through the alpha network |
| `{:event, event}` | telling a listener is not a node's business |

That is the whole mechanism. Adding an event is a change in one function.

### Cost when nobody is listening

The engine's `emit` helper takes a **function**, not a term, and returns immediately
when the listener list is empty. An unobserved session therefore allocates
nothing and calls nothing — measured at no difference over a 300-fact session.

### State

`listeners: [{module, state}]` on `Rete.Engine.State`. A list rather than a map,
so the attach order is the event order and one module can be attached twice with
different state. Listener state lives on the session, so a session with listeners
is still an immutable value: no processes, no ETS, no side channel.

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

`source` is `%{node: node_id, rule: {module, name}}`. A listener is handed an event and
its own state and cannot reach the network, so a bare node id would be an integer it had
no way to resolve — and `{module, name}` is the identity `Rete.Session.query/3` and
`Rete.Inspect.why_not/2` already use. A map rather than a wider tuple, so a field can be
added later without changing the shape every listener matches on. `{:propagated, ...}` is
the exception and keeps the bare id: it fires for every node, and a join has no name.

`origin` is `:asserted` or `{:derived, source}` — the same map, so a concluded fact can be
attributed to the rule that concluded it. That single distinction is what lets a listener
reconstruct provenance from events alone, without reading memory.

A listener **must** have a catch-all clause; new events are added as the engine
grows, and one that crashed on an unfamiliar event would make upgrading a
breaking change.

Shipped: `Rete.Listener.Collect` (records everything; the substrate for tests)
and `Rete.Listener.Trace` (a readable line per event, propagation events behind
`verbose: true`).

---

## 2. Inspection

`Rete.Inspect` works on **any** session with no listener attached, because truth
maintenance already records what it needs. `memory.insertions` is
`node_id => token => [[facts]]` — "this match at this production inserted these
facts" — which read backwards is exactly a provenance edge. A token's `:matches`
is the ordered list of facts behind it. Walking those two is the whole of
`explain/2`.

Prefer the memory-derived answer wherever there is one: it needs no setup and
cannot drift from reality. Listeners add only what memory cannot know — history,
ordering, and activations that fired and were later retracted.

| function | question |
|---|---|
| `explain/2` | why does this fact exist? |
| `fired/2` | which rules have concluded something? |
| `why_not/2` | how far did this rule get? |
| `collection/3` | what did this collection gather? |

### `explain/2` returns a list

One entry per **independent support**. A fact concluded by two rules, or by one
rule through two matches, has two supports and needs both to go before it does —
so reporting only the first would be a lie of exactly the kind that makes
retraction look broken.

### What is translated rather than leaked

* **Marker facts.** A compound negation compiles to a generated helper that
  inserts a marker. It must be a real fact for the negation to match on, but it
  is not a user conclusion: `Session.facts/1` hides it, and `explain/2` skips it
  when walking supports.
* **The root token.** A rule opening with a negation or collection is anchored on
  a seeded empty token. It is not a matched fact and is never presented as one.
* **Generated helpers.** `fired/2` hides them unless `generated: true`, and
  `why_not/2` does not suggest them in its "no such rule" error.
* **Collections.** A token records the gathered *list*; `explain/2` expands it
  into its members, which is what the user recognises.

### Reading `why_not/2`

It reports `:elements` (facts matching this condition alone) and `:tokens`
(partial matches arriving from the left) separately, plus `:activations` on a
terminal. Deliberately **not** one "matches" number: a root join holds elements
and emits tokens without storing them, and a production holds neither. A single
column would mean something different at every node and read as `0` where nothing
is wrong.

Read it left to right and find the first node where the two disagree:

```
node 9  root_join  :cust   elements=2 tokens=0     two customers matched
node 10 negation   :order  elements=1 tokens=2     both reached here; one order suppressed one
node 11 production         elements=0 tokens=0 activations=1
```

---

## 3. The loop guard

`fire_rules/2` runs to quiescence. It caps activations only when asked —
`:max_cycles`, `:infinity` by default — and raises when the cap is hit.

**Opt in rather than on by default**, which is the same call Clara makes: its
`clara.tools.loop-detector/with-loop-detection` wraps a session and takes
`max-cycles` as a required argument, with no default anywhere.

The reasoning is that a count cannot tell the two cases apart. Twelve thousand
activations is four thousand facts through a three-rule chain, and it is also a
loop that has gone round twelve thousand times. So a default is a guess about how
much legitimate work is too much, and it fails on the session that outgrows it —
returning an answer that is not late but *wrong*, because the engine stopped part
way through settling. An uncapped run has the opposite failure: an oscillating
ruleset spins with no output until it is interrupted. Between a wrong answer and
a visible hang, this engine takes the hang and hands the judgement to the caller,
who knows whether they are in a test suite or a batch job.

### Choosing a number

Worth setting wherever a hang is more expensive than a false alarm — a test suite, a
request handler, a first run of a rule someone just wrote. The cost of setting it too
high is what the worst runaway does before it trips. That is a rule concluding a fact its
own left hand side matches, which grows working memory by one fact per activation,
measured at about 3.5 ms and 0.46 MB per thousand:

| `max_cycles` | raises after | heap used |
|---|---|---|
| 10,000 | 35 ms | 0.5 MB |
| 100,000 | 270 ms | 46 MB |
| 500,000 | 1.7 s | 230 MB |

Against that, the cost of setting it too low is a `RuntimeError` on work that was fine.
The error says to raise it, so that mistake announces itself. A hang does not.

Clara counts transitions between *activation groups* rather than activations.
That is a better signal in principle, but it has a failure mode this does not: a
loop confined to a single salience level produces no group transitions at all,
and the common runaway — a rule concluding something its own LHS matches — sits
at one salience.

What the cap does well is the **message**. Pending activations describe whatever
happened to be queued when it hit, which for a loop is arbitrary. The error leads
with which rules fired most, which is what identifies the loop:

```
Fired most:
  20x  MyRules.grow

Still pending (5 of 12 activations):
  MyRules.grow %{n: 20}

A rule that concludes something its own left hand side matches on will do this.
```

Both lists are cut to five and say so when they cut, because a truncation that
says nothing reads as the whole story.

A configurable action (Clara's `:throw-exception` / `:standard-out-warning`) was
**not** added. Nothing needs it yet, and a caller who wants to log and continue
can catch the error.

---

## 4. Known gaps

* **`why_not/2` follows one parent.** A node reached through a disjunction has
  several; the first is enough to show where a chain broke without turning the
  output into a tree, but a rule whose branches fail differently will only show
  one of them.
* **`fired/2` is a snapshot, not a history.** It reads truth maintenance, so a
  rule that fired and was later retracted does not appear. Attach
  `Rete.Listener.Collect` and read `:activation_fired` for that.
* **No "why did this fact *not* get concluded".** `why_not/2` answers it for a
  named rule; there is nothing that starts from a hypothetical fact and works
  backwards.
* **`Listener.Collect` grows without bound.** Fine for a test or a debugging
  session, not for a long-lived one.
