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

`Rete.Listener` lists the events and the shape of each. What matters here is **when** they
reach a listener, which follows from the two loops rather than from the list.

Only two of them reach a listener outside a fire. `insert/2` and `retract/2` emit
`:fact_inserted` and `:fact_retracted`, because they update working memory at once. One
event per occurrence: a fact inserted twice emits two. Everything else happens inside
`fire_rules/2`, which is the only call that propagates. That covers every `:propagated`
event and every `:activation_*` one. See `engine.md` §2.

That is what lets a listener see a whole settle. Attach it to a fresh session. No matching
has happened yet, so the listener misses nothing.

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

`Rete.Inspect` needs **no listener and no setup**, because truth maintenance already
records what it needs. `memory.insertions` is `node_id => token => [[facts]]`: "this match
at this production inserted these facts". Read backwards, this is exactly a provenance
edge. A token's `:matches` is the ordered list of facts behind it. `explain/1,2` just walks
these two structures.

Prefer the memory-derived answer wherever one exists. It needs no setup, and it cannot
drift from reality. Listeners add only what memory cannot know: history, ordering, and
activations that fired and were later retracted.

| function | question |
|---|---|
| `explain/1,2` | what did this rule do, and what is behind each match? |
| `why_not/1,2` | how far did this rule get? |

Both are addressed the same way. A `{module, name}` pair asks about one rule or query. No
pair asks about every rule and query in the session. That pair is the only address either
one takes, and it is the pair you wrote in `defrule`.

### Both need a settled session

Both read what propagation built, and propagation waits for `fire_rules/2`. On a session
with work queued they would report zero of everything, which reads as "nothing matched"
when the truth is "nothing has been matched yet". They raise instead, and name the pending
count. A diagnostic that lies is worse than one that refuses.

A session that fired and was then inserted into is refused too. Its counts are real, and
they describe a network the newest facts have not reached. That is the same failure wearing
plausible numbers.

`Rete.Session.query/3` is deliberately not guarded this way: it is asked what matched, and
`[]` is a true answer. See `engine.md` §2.

### Provenance is one level deep

Each entry of an activation's `:matches` says where its fact came from. `:from` is the list
of rules that concluded it, and you follow one of those pairs to its own entry in the same
result. A tree instead would repeat the same subtree under everything resting on it. It
would then grow with the depth of a derivation chain, and not with the number of matches.

`:from` is a **list**, and that is not incidental. A fact concluded by two rules, or by one
rule through two matches, has two independent supports, and it needs both to go before the
fact itself goes. Reporting only the first would be exactly the kind of lie that makes
retraction look broken.

### There is no separate reader for collections

A collection propagates only its result, so its members would be invisible once a token has
moved on. They are not, because `Rete.Engine.Nodes` extends the token with the gathered list
itself, and for a filtered collection that list is already what the filter kept. So an
activation carries the collection the rule received, and `explain/2` reports it under
`origin: :gathered` with each member described in `:members`.

This used to be `collection/3`, which took a node id and a **join key**. The join key is
whatever `Rete.DSL.Bindings` classified as `join_bind` for that node, and nothing public
reports it, so a caller had to guess. A wrong guess answered `[]`, which is what "gathered
nothing" also answers. Keyed by the activation, there is nothing left to guess.

### What is translated rather than leaked

* **Marker facts.** A compound negation compiles to a generated helper that inserts a
  marker. The marker must be a real fact, for the negation to match on it. But it is not a
  user conclusion: `Session.facts/1` hides it, and `explain/2` skips it when reading a
  token's matches.
* **The root token.** A rule opening with a negation or collection is anchored on a seeded
  empty token. It is not a matched fact, and it is never presented as one. A rule with no
  conditions therefore reports one activation with no matches.
* **Generated helpers.** The arity-1 forms leave them out, and `why_not/2` never suggests
  them in its "no such rule" error. Name one explicitly and either function answers.
* **Collections.** A token records the gathered *list*, and that list is reported whole
  under `origin: :gathered`, because it is what the rule received. `:members` describes
  each fact in it, so a gathered fact a rule concluded still names that rule.

### Reading `why_not/1,2`

The `:chain` reports `:elements` (facts matching this condition alone) and `:tokens`
(partial matches arriving from the left) as separate numbers, plus `:activations` on a
terminal. It deliberately avoids one "matches" number. A root join holds elements and emits
tokens without storing them. A production holds neither. A single column would mean
something different at every node, and it would read as `0` where nothing is actually wrong.

Read the chain in order and find the first node where the two disagree:

```
node 9  root_join  :cust   elements=2 tokens=0     two customers matched
node 10 negation   :order  elements=1 tokens=2     both reached here; one order suppressed one
node 11 production         elements=0 tokens=0 activations=1
```

### Why these two, and not more

`explain` and `fired` were once separate, and both read `memory.insertions`: `fired`
forwards, `explain` backwards through the `inserters` index. One rule-keyed report answers
both questions, which is the shape Clara's `clara.tools.inspect/inspect` returns. Every
address either function takes is now a `{module, name}` pair the caller wrote. No function
here asks for a node id or a join key that only the compiler knows.

---

## 3. The loop guard

`fire_rules/2` fires until the agenda is empty. `:max_cycles` bounds that, and it is
**100,000 by default**. The engine raises an error when the cap is hit, and the error names
the rules that fired most. Pass `:infinity` to remove the cap.

A **cycle** is one pass of the fire loop. At the default concurrency, one pass takes one
activation. Above the default, one pass takes one whole activation group. The cap bounds
passes, not activations. So raising `:concurrency` fires the same work in fewer, larger
cycles, instead of consuming the allowance faster. See `engine.md` §11.

**The default is a cap, and Clara has none.** Its
`clara.tools.loop-detector/with-loop-detection` wraps a session and takes `max-cycles` as
a required argument. This engine departs from Clara here, and 0.9.0 is where it did.

A count cannot tell two cases apart. Twelve thousand activations could be four thousand
facts moving through a three-rule chain. It could also be a loop that has gone round
twelve thousand times. So any cap is a guess about how much legitimate work is too much.
That guess fails on the session that outgrows it, and the failure is loud: a
`RuntimeError` on work that was fine, telling the caller to raise the limit.

An uncapped run fails the other way, and quietly. A ruleset that never settles spins with
no output, and it grows working memory until something interrupts it. Nothing in the
engine detects the shape that causes it, which `engine.md` §8 states. Before 0.9.0 the
well-founded check made the commonest such rule settle on a truncated answer, so an
uncapped default was survivable. That check is gone, so the rule now spins.

Between a false alarm that says what to do and a silent hang, this engine chooses the
false alarm. A caller who knows their ruleset settles can still say `:infinity`.

### Choosing a number

Lower `:max_cycles` wherever a hang costs more than a false alarm: a test suite, a request
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

The default is the middle row, and the row above it is why. A **cycle is one activation**
at the default concurrency. 10,000 of them is a batch of 4,000 facts moving through a
three-rule chain, which `mix bench` does in "truth maintenance through a chain" with no
loop in sight. The default has to clear ordinary settling work by a wide margin, and
100,000 clears that scenario eight times over.

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

Still pending:
  MyRules.grow %{n: 20}

A rule that concludes something its own left hand side matches on will do this.
```

Both lists are cut to five items, and only the rules say so. How many rules are in the
loop is the thing being reported, so a silent cut there would read as the whole story.

The pending list carries no count. Its length is the fan-out at the moment the cap hit,
which is a property of the queue rather than of the loop. The `fired n cycles` line already
gives the scale. It used to say `(5 of 12 activations)`, and the agenda kept a running
count of its activations to answer it. Nothing else ever asked, so the count is taken
over the buckets now, on the rare occasion something does.

This engine does **not** add a configurable action, unlike Clara's `:throw-exception` /
`:standard-out-warning`. Nothing needs it yet. A caller who wants to log and continue can
just catch the error.

---

## 4. Known gaps

* **`why_not/1,2` follows one parent.** A node reached through a disjunction has several
  parents. The first is enough to show where a chain broke, without turning the output
  into a tree. But a rule whose branches fail differently will show only one of them.
* **`explain/1,2` is a snapshot, not a history.** It reads truth maintenance, so a rule
  that fired and was later retracted reports no activation for that match. Attach
  `Rete.Listener.Collect`, and read `:activation_fired` events for that instead.
* **A rule that concludes nothing reports no activation.** Truth maintenance records a
  match only where a conclusion rests on it, and a production keeps no tokens of its own.
  So a body returning `nil` or `[]` fires and leaves nothing behind to read, and
  `activations: []` cannot be told apart from a rule that never matched. Clara splits the
  same way: its `:rule-matches` holds only the matches with a logical insertion. A listener
  sees these firings, as an `:activation_fired` event carrying no facts.
* **No "why did this fact *not* get concluded".** `why_not/1,2` answers that for a named
  rule. Nothing starts from a hypothetical fact and works backwards.
* **`Listener.Collect` grows without bound.** Fine for a test or a debugging session, not
  for a long-lived one.
