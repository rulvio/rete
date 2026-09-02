# The engine

This document covers what runs the network that `network.md` describes. It is the
companion to `ir.md` (the DSL front end) and `observability.md` (listeners, inspection,
the loop guard).

Status: implemented, end to end.

| module | file | what it is |
|---|---|---|
| `Rete.Token`, `Rete.Element`, `Rete.Activation` | `lib/rete/token.ex` | what travels |
| `Rete.Memory` | `lib/rete/memory.ex` | the five working memories |
| `Rete.Agenda` | `lib/rete/agenda.ex` | salience-ordered activations |
| `Rete.Engine.State` | `lib/rete/engine/state.ex` | everything that changes, as one value |
| `Rete.Engine.Nodes` | `lib/rete/engine/nodes.ex` | what each node kind does |
| `Rete.Engine` | `lib/rete/engine.ex` | the propagation loop and the fire cycle |
| `Rete.Session` | `lib/rete/session.ex` | the public API |

---

## 1. The one decision everything follows from

Clara propagates by **mutating a transient memory**, while calling down the node tree. At
the end of `fire-rules`, it converts that memory back to a persistent one. This duality is
why Clara needs an `ITransport` abstraction, four activation protocols, and seventeen
listener methods sprinkled through every node.

This engine runs a **flat propagation loop over an explicit work queue** instead. A node
is a function of state. It returns the new state, plus the work it produced. The loop does
the walking:

```elixir
# lib/rete/engine/nodes.ex
handle(state, {op_kind, node_id, items}) :: {state, [op]}
```

Four consequences follow, and all of them are load-bearing:

* **no transport abstraction.** That would have been indirection for a distributed
  transport that never shipped.
* **one immutable `Rete.Memory`**, threaded through a fold. So a session is a *value*:
  holdable, comparable, forkable, and sendable between processes with no coordination.
* **propagation is flat iteration.** A cascade of any depth costs no stack.
* **events are emitted in exactly one place** — the loop — instead of in every node. That
  is what made the listener work in W5 cheap.

## 2. Two nested loops

```
insert / retract  ->  enqueue alpha ops  ->  drain
fire_rules        ->  drain, then: pop the most salient activation, run it,
                      insert what it returned, drain, repeat until the agenda is empty
```

**Propagation drains to completion before the next activation fires.** A rule must see a
settled network, or it could act on a half-built match.

`fire_rules/2` returns at **quiescence**. Every rule whose left hand side holds has fired.
Nothing is still asserting anything whose support has gone. This is the point where a
session is consistent, and it is the only state the public API ever hands back.

### Ops

| op | carries | produced by |
|---|---|---|
| `{:left, node_id, tokens}` | tokens from a parent | any node propagating downstream |
| `{:right, node_id, elements}` | elements from an alpha | `Rete.Engine`, on insert |
| `{:left_retract, ...}`, `{:right_retract, ...}` | the same, going away | retraction |
| `{:retract_facts, node_id, facts}` | conclusions to take back | a `Production` whose token was retracted after it fired |
| `{:event, event}` | a listener event | any node with something to report |

The last two ops are work a node cannot carry out where it happens. Retracting has to
re-enter the **alpha** network, which only the engine can reach. Telling a listener is not
a node's business either.

## 3. What travels

**`Rete.Element`** — a fact that matched one condition, plus the bindings that match
produced. Elements arrive from the right.

**`Rete.Token`** — a partial match: `:matches`, the `[{fact, node_id}]` behind it *in
order*, and `:bindings`, the variables bound so far. Tokens arrive from the left.

The engine compares both **by value**. Two tokens over equal facts with equal bindings are
the same match, whoever produced them. This is what makes retraction work, even when the
term that triggered it is a different term of the same value. Match *order* is part of a
token's identity: two tokens over the same facts, in a different order, are different
matches.

**`Rete.Activation`** — a production node plus the token that satisfied it, plus the
salience and compile order it will be sorted by.

## 4. The six memories

```
elements    node_id => join_key => Bucket of Element   right side of a beta node
tokens      node_id => join_key => Bucket of Token     left side of a beta node
accum       node_id => join_key => group_key => tree   what a collection gathered
insertions  node_id => token => [[fact]]               truth maintenance
inserters   fact => {node_id, token} => count          the same, read backwards
facts       fact => count                              what the session holds
```

Three properties matter more than the shapes.

**Keyed by value, so removal must collapse.** A join key and a group key hold the bindings
they were built from. An entry left pointing at an empty leaf is not untidiness — it is a
leak. That leak grows with the number of distinct entities the session has ever seen.
`Rete.Engine.Nodes` depends on this collapse, because "no group" and "an empty group" are
different answers. Only a level that really is gone may disappear.

**Multisets, not sets.** `facts` counts occurrences. Inserting the same fact twice, then
retracting once, must leave it present. Two rules may each have concluded it, and
invalidating one of them does not make the fact false. `elements` and `tokens` are lists
for the same reason. The engine retracts them one occurrence at a time.

**`insertions` is the provenance graph.** "This match at this production inserted these
facts" — read backwards, this is exactly the edge that `Rete.Inspect.explain/2` walks. No
separate bookkeeping exists for explanation.

`inserters` is that same relation, indexed the other way, and it is the one derived thing
in here. Both its readers ask "which matches inserted *this fact*": `well_founded/3` on
every conclusion that turns out to be already present, and `Rete.Inspect.derivations/2`
per fact. Answering that from `insertions` costs a pass over every insertion record in the
session, which made two rules concluding one fact quadratic in the number of conclusions —
and two rules concluding one fact is the ordinary shape of truth maintenance, not a
pathology. It is maintained in `Rete.Memory.add_insertion/4` and `take_insertion/3`, the
only two places `insertions` is written, and a property rebuilds it the slow way and
compares. It is a multiset keyed on `{node_id, token}`, rather than a list of tokens, so
that two memories holding the same matches compare equal whatever order they reached them
in.

Keeping it costs about 13% of a settling pass that never re-concludes anything, measured
on 4,000 facts through a three-rule chain. That is the trade: a constant on every
conclusion, against a quadratic on the conclusions that repeat.

`root_seeded?` is the one field that is not a memory — see §6.

## 5. Node behaviour

Every clause of `Rete.Engine.Nodes` has the same shape. It takes the state and the items.
It returns the new state, and the work produced.

| node | left (tokens) | right (elements) |
|---|---|---|
| `RootJoin` | ignores | mints one token per element |
| `HashJoin` | stores, joins against stored elements on `:join_bind` | stores, joins against stored tokens |
| `ExprJoin` | as `HashJoin`, then `:filter.(token_bindings, fact_bindings)` | the same |
| `Negation` | propagates while **no** element matches on `:join_bind` | arriving suppresses matching tokens; leaving releases them |
| `NegationJoin` | as `Negation`, with the filter deciding what counts as a match | the same |
| `Accumulate` | emits the gathered list under `:coll_binding` | re-emits the group it changed |
| `AccumulateJoin` | as `Accumulate`; candidates cannot be reduced until a token exists | the same |
| `Test` | propagates when `:fun.(bindings)` is truthy | nothing — a test has no fact input |
| `Production` | adds an activation to the agenda | nothing |
| `Query` | stores the token for lookup | nothing |

### The retraction rule

**Every node must retract exactly what it propagated**: the same value, not something
merely equivalent. Downstream memories remove by value. A mismatch leaves a token stranded
forever, and that stranded token later fires a rule whose support is gone.

One discipline makes this hold. A node never propagates from what it was *handed*. It
propagates from what its memory says, *after* the memory update. `Rete.Memory.remove_elements/4`
and `remove_tokens/4` report only the occurrences they actually held, and the node
propagates only those onward. A retraction of something never stored produces no
downstream work at all.

This is the one contract no end-to-end property test can reach — every one of them still
passes even with the filtering removed. So the test suite checks it directly against the
memory instead.

### A collection is one match, not many

An accumulate node emits the gathered **list** as a single binding. Change any member, and
the list becomes a different value, so it is a different token. The old token is
retracted, the new one propagates, and truth maintenance replaces the conclusion. That is
why a rule over a collection fires once per group, not once per gathered fact.

The engine gathers in **reverse arrival order** — a member is prepended, nothing is sorted
— so the stored list *is* the value the rule receives. That is what makes a member change
cheap: the old collection and the new one are both in hand, sharing every cons cell but
one, with nothing built to produce either. Sorting instead would mean walking the group to
find each member's position, which is O(k) per change and quadratic over a group's life.

A collection's *order* is therefore not a function of its fact set; its *membership* is.
The engine used to sort to make the order one too, which nothing had asked for and every
collection paid for. See `network.md` §3, and `docs/dsl.md` for the rule it puts on rule
authors.

## 6. The root token

Nothing binds before a rule's first condition. So a rule that opens with a negation, a
collection, or a test has no element to build its first token from. A `RootJoin` does not
need one. But a `Negation` hanging off the beta root has to pass *something* while nothing
matches. An `Accumulate` there has to emit its collection to someone too.

Classic Rete answers this with a single empty token, seeded at the root, and this engine
does the same. It plants that token at **state creation**, not on the first fact. A rule
whose whole left hand side is an absence, or an empty collection, is true of the empty
session, and it must be able to fire before anything is inserted.

`Rete.Memory.root_seeded?` makes seeding idempotent. A second root token would give every
such rule a second support, and no retraction would ever clear it.

It is machinery, not a match. `Rete.Inspect` never presents it as a fact.

## 7. Firing

The engine orders activations by `{salience, internal_salience}` descending, then compile
order ascending. Compile order — not map order — is what makes two rules of equal salience
fire in the order they were written. A rules engine whose output depends on map iteration
order would be impossible to reason about.

`internal_salience` is the tier that makes an extracted negation helper fire before the
rule that negates its marker. Without it, the negating rule would observe an absence that
was merely not computed yet. It would fire, then get retracted — a visible, spurious
activation. This field is reserved. A rule that sets it raises an error.

The agenda is **bucketed by sort key**, not a heap. Removal by value is the common
operation here, not an afterthought: an activation is a *pending* match, and the facts
behind it can be retracted before it fires. `Rete.Agenda.remove/2` reports whether it
found the activation. That is exactly the distinction a production needs on retraction.
Either the match never fired and never will, or it fired, and its conclusions have to be
taken back.

Every activation of one production shares a key. Salience, internal salience, and compile
order all come from the node, none from the match. So there are at most as many buckets as
there are production nodes, however many facts a session holds. A single sorted list,
instead, would walk past every match already queued for the same rule, on every insertion.

### Two matches of one rule

Two matches of one rule fire in **arrival order**. That guarantee runs deeper than the
agenda. It holds because each of these steps preserves arrival order, in turn:

* a bucket hands its items back in the order they were pushed (`Rete.Bucket`).
* a batch of items arriving at a node splits into join groups in the order each key first
  appeared, not in map order. `Enum.group_by/2` returns a map. Elixir iterates a map of up
  to 32 keys in term order, and a larger map in an internal hash order — so taking that
  order would change a rule's firing sequence the moment a node saw its 33rd join key.
* the agenda appends within a bucket, rather than inserting.

None of this changes what a session *concludes*. That outcome is order-independent, and
the property suite confirms it. What arrival order does decide is the order
`:activation_fired` events arrive in — and that is what anyone reading a trace relies on.

### What arrival order does not promise

**Order within one parent, not across parents.** `Rete.Engine.coalesce/1` merges the ops of
one insert or retract call that go the same way to the same node, so a node is handed a
whole batch at once instead of one element per call. Ops keep the position of the first
fact that produced one for a given child, so a rule's own matches still arrive in fact
order — which is the guarantee above, and the one rules rest on.

What changed with it: a rule reachable by **two different routes** within a single call now
sees all of one route's matches before any of the other's, where it used to see them
interleaved fact by fact. Inserting `{:n, 5}` and `{:n, 6}` into a rule whose two
disjunction branches both match them fires `5, 6, 5, 6` and used to fire `5, 5, 6, 6`. Both
are arrival orders. Only the first is stable when one fact type feeds several conditions,
and the settled facts are identical either way.

That is pinned by a test rather than left to the suite, because the suite stayed green
through the change: nothing else reads the sequence, only what the session settles to.

Batching is not a micro-optimisation. A node's per-call work is not all per item — it
dispatches, groups by join key, and at a negation or a collection reads back what it
already holds. Paying that once per fact is what made an unkeyed negation and a live
collection quadratic. The `{:propagated, op, node_id, count}` event coarsens with it:
fewer events, larger counts, same shape.

## 8. Truth maintenance

Facts a rule inserts are **logical**. They exist only while the match that concluded them
still exists. The engine records each insertion against its token. Retracting that token
retracts the facts, which may retract the support of other conclusions, cascading until
the session settles.

This is why the right hand side inserts, and never retracts. A rule says what follows from
a match. Keeping that true, as facts change, is the engine's job. With no unconditional
insert, there is no way to leave behind a conclusion whose support is gone.

### Support is well founded, not merely counted

A match that rests on the very fact it concludes would support that fact with itself. Its
count would never reach zero. The fact would survive the retraction of everything the user
ever asserted, and the memories behind it would never drain.

```elixir
defrule symmetric({:edge, a, b}), do: {:edge, b, a}
```

One `{:edge, 1, 2}` concludes `{:edge, 2, 1}`, which concludes `{:edge, 1, 2}` right back.
So the engine **drops** a conclusion the match already depends on: it is not inserted, not
recorded, and its count is not bumped. This check runs only when the fact is already
present, since that is the only way the loop can close. It walks the insertion records,
not the network.

Deciding this at insertion time, instead of re-deriving it on every retraction, has one
limit. The dropped support is never reconsidered later. If the grounded route to a fact
goes away, while the circular one would still have held, the fact goes away with it.

## 9. Queries

A query terminal stores the tokens that reach it, instead of activating.
`Rete.Engine.query/3` returns their `:bindings`, filtered by equality against the given
parameters. `Rete.Compiler` rejects, at build time, a parameter the left hand side does
not bind on every path — such a filter could never be satisfied.

A query reads the session as it stands. So a query answered before `fire_rules/2` reports
what was true before the pending activations fired.

## 10. What is asserted about all of this

Facts alone are a weak lens for testing. If a node propagates a token it had already
propagated, the duplicate fact just collapses into a count bump in the multiset.
`Rete.Session.facts/1` still looks perfect. The corruption surfaces much later, as a fact
that survives a retraction that should have removed it.

The test suite therefore asserts on `session.state.memory` instead. These four invariants
are the ones that actually catch engine bugs:

* **full drain.** Retract everything. Every memory then equals a **fresh session's**
  (`Rete.Session.new([Mod]).state.memory`). This pins both "drained" and "exactly one root
  token" — an emptiness check alone cannot see either one.
* **support counting.** A fact concluded by exactly one match is held exactly once. Two
  supports need two retractions, and the first retraction leaves the fact standing.
* **round trip.** Insert X, fire, retract X, fire, and compare against the state before.
* **order independence.** The same facts, in any order and any batching, give the same
  derived state. Any sequence of inserts and retracts leaves a session equal to one
  rebuilt from the surviving facts.

One more invariant needs a direct test against the memory, since no end-to-end property
reaches it: **a memory reports the occurrences it actually held, not the ones it was asked
to remove**.

---

## 11. Firing bodies concurrently

`fire_rules/2` takes `:concurrency`, which defaults to `1`. Above `1`, it pops a whole
**activation group**: every agenda bucket sharing the leading `{salience,
internal_salience}`. It runs those rule bodies on tasks, then applies their conclusions in
group order.

### Only the body moves

`fire/2` splits into a pure half and a stateful one:

```elixir
node.rhs |> apply([node.hash, activation.token.bindings])  # pure: hash + frozen bindings
|> normalize_facts()                                        # pure
|> check_facts!(state, node, token)                         # reads the immutable taxonomy
|> well_founded(state, token)                               # reads state.memory
```

Only the first two lines run on a task. `well_founded/3` reads working memory, and one
activation's conclusions can retract the support of another. `Rete.Agenda.remove/2`'s
`:removed`/`:missing` split detects exactly that case. So the engine applies conclusions
one at a time, with a `drain()` between each. A rule still sees a settled network this
way.

The task closure captures `{rhs, hash, bindings}`, and nothing else. Closing over the
state or the network would copy the whole compiled network into every task.

### Why the default is 1

A body that builds a tuple is **1.5%** of `fire_rules`. The other 98.5% is propagation. A
task costs about 3.5 µs per activation, so parallelising cheap bodies is a large net loss.
Measured over 2,000 activations, on 16 cores:

| body cost | sequential | concurrent | speedup |
|---|---|---|---|
| 0 µs | 0.8 ms | 7.1 ms | 0.12× |
| 1 µs | 2.2 ms | 7.3 ms | 0.29× |
| 5 µs | 10.1 ms | 9.6 ms | 1.05× |
| 100 µs | 200.1 ms | 44.2 ms | 4.52× |
| 500 µs | 1000.1 ms | 78.7 ms | 12.72× |

Break-even is about 5 µs. That is far above anything a pure body does, and far below any
I/O. So this option pays off exactly when a body waits on something. Sixteen bodies
sleeping 20 ms each go from 335 ms to 21 ms.

### What it does and does not preserve

It **preserves the resulting session**, down to the truth-maintenance ledger. A property
test over the every-node-kind ruleset asserts this, for concurrency 2 through 8.

It **does not preserve firing order**. This follows from batching itself, not from this
particular implementation. Firing one at a time re-sorts the agenda after every
activation, so a rule activated by another's conclusion can overtake one that was already
pending. Popping a whole group instead freezes it, so the new activation waits for the
next group:

```
sequential   a → b → c    b, activated by a, overtakes the already pending c
concurrent   a → c → b    the group {a, c} was frozen before a ran
```

It also **does not guarantee a body runs only for matches that survive**. A body may run
for an activation that another activation, in the same group, then invalidates. The engine
discards what it computed: that activation does not fire, and `Rete.Agenda.remove/2`
returning `:missing` is what detects the case. But a side effect the body performed is not
undone. Clara documents the same behavior for `fire-rules-async`. `docs/dsl.md` states the
at-least-once contract this implies.

Discarding rather than applying is the whole reason the group is peeked, instead of
popped. Taking the group off the agenda up front would leave a later retraction nothing to
cancel. The conclusion would then be inserted against a token that no longer existed, and
no retraction could ever take it back. `Rete.EngineTest` checks both halves: the
activation does not fire, and the session still drains to empty.

### What a body runs in

A body runs on a `Task`, which means the usual process-boundary rules apply:

* `$callers` **is** set. So `Ecto`'s SQL sandbox, and anything else that walks the caller
  chain, keeps working.
* `Logger.metadata` is **not** inherited. A body that logs loses the request metadata of
  the process that called `fire_rules/2`. Read that metadata before firing, and either
  pass it in a fact or set it inside the body.
* the task **copies** the bindings. This costs nothing for scalars, but a collection
  binding copies the whole gathered list. Measured on 20 collections of 2,000 elements
  each: 0.1 ms at `concurrency: 1`, 1.6 ms at `concurrency: 8`. A collection rule looks
  cheap, but it is expensive to hand over. It needs a genuinely slow body before raising
  `:concurrency` pays off.

### The result buffer is not chunked, deliberately

`Task.async_stream` with `ordered: true` does **not** bound its buffer. With a slow first
item, every later item completes and waits, held until the first item can be emitted. So a
whole group's results can sit in memory at once.

Chunking the stream would bound that memory. This was measured, not assumed, and it is not
worth it. A group of 50,000 activations peaks at 66 MB sequentially, and at 79 MB at
`concurrency: 8`. The group itself dominates that cost, and the buffer adds only about 20%
on top of a cost both paths already pay.

Against that, chunking costs throughput badly, because every chunk waits for its slowest
member. On 256 bodies at `concurrency: 8`, with 10% stragglers, perfect scheduling would
take 296 ms:

| | wall clock |
|---|---|
| unchunked | 360 ms |
| chunks of 8 (1× concurrency) | 1224 ms |
| chunks of 32 (4×) | 551 ms |
| chunks of 128 (16×) | 399 ms |

Paying 3.4× throughput to save 20% memory is the wrong trade, for the workload
`:concurrency` exists for. If a group ever grows large enough for the buffer to matter, a
bounded-window pipeline could get both — spawn ahead, then apply results in order as they
land. The cost is hand-rolling what `Task.async_stream` already does.

### A cycle is a group, not an activation

`:max_cycles` counts passes of the fire loop. At the default concurrency, one pass takes
one activation. Above the default, one pass takes one whole activation group. So a group
is a single cycle, however many activations it holds.

This is the point, not a leak. Raising `:concurrency` does not consume the cycle allowance
faster. It fires the same work in fewer, larger cycles. 500 pending matches of one rule
are 500 cycles, one at a time, or one cycle, as a group. An oscillating ruleset is still
caught either way, because each round trip of the oscillation is its own cycle.

This also narrows the known gap below. Clara counts transitions between activation groups.
Above `concurrency: 1`, this engine counts them too.

### Errors

The engine catches a body's error on the task, and reraises it in the caller, with its
original stacktrace. That stacktrace already names the generated `__rhs_<name>__` frame.
Without it, a rule body's exception would surface as an opaque task exit instead.

The engine re-throws a throw with `:erlang.raise/3`. A `:timeout` kills the task. Since
there is then no original error to reraise, this one case raises a `RuntimeError` naming
the rule instead.

---

## 12. Known gaps

* **Removing a collection member is O(position), and a filtered collection is O(k) per
  token.** Adding is O(1) — the stored list is the binding, and a member is prepended — but
  removal walks to the member, and an `AccumulateJoin` has to re-decide membership per
  token from the bindings its alpha produced, so it cannot share one value the way a plain
  collection does. Neither is quadratic in a session, and both are measured.

  Neither is fixed by Clara's accumulator abstraction, and it is worth being exact about
  that, because the abstraction is otherwise worth having. Clara's `acc/all` removes with
  `drop-one-of`, which walks the collection twice and rebuilds it into a fresh vector,
  where `List.delete/2` here walks once and shares the tail past the removal point. Its
  `min` and `max` carry no `retract-fn` at all and re-reduce the whole group on every
  retraction. On removal from a gathered collection this engine is the faster of the two.

  What the abstraction is actually for is **not gathering a collection in the first
  place**. `count`, `sum` and `average` bind a number, with `retract-fn` of `dec` and `-`,
  so both directions are O(1); `distinct` binds a frequency map. The saving is not the
  arithmetic, it is that the token then carries a scalar: nothing allocates a k-element
  list per member change, and nothing hashes or compares one in the memories downstream.

  The benchmark rule here is the case in miniature — `orders = [...]` followed by
  `length(orders)` builds the whole list on every change so that the body can measure it
  and discard it. Most collection rules reduce. A `defrule` that could say so is the
  natural next step if collections turn out to matter in practice; a rule that genuinely
  wants the list would be no better off.
* **A dropped circular support is not reconsidered.** See §8.
* **The loop guard counts activations, not activation-group transitions.** Clara's signal
  is better in principle — a ruleset that legitimately fires 50,000 activations in one
  settling pass is fine. But Clara's signal misses a loop confined to a single salience
  level, and that is the common runaway. See `observability.md` §3.

  This gap is resolved by not guessing at a default. The default cap was 10,000, until
  `mix bench` reached it with 4,000 facts moving through a three-rule chain — 12,000
  activations, with no loop in sight. The guard is now `:infinity` by default, the same
  opt-in call Clara makes. A count cannot separate a runaway from a large settling pass.
  So any default eventually fails correct code, and stopping part way through settling
  returns an answer that is wrong, not just late. The cost: an oscillating ruleset now
  spins until something interrupts it. `observability.md` §3 carries the numbers for
  choosing a cap where that matters.
* **No partial firing.** `fire_rules/2` runs to quiescence in the calling process. There
  is no fire-one-activation option, no async variant, and no way to interrupt a settling
  pass other than the cycle cap.
* **No checkpoint or migration API, but a session is trivially serializable.** A session
  holds no PID, ETS table, or other process-local handle. It is plain data, plus function
  references into the ruleset and listener modules that built it. Because of this,
  `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` round-trip a whole session,
  including its compiled network, with no wrapper needed. What is still missing: a
  checkpoint API, versioned migration, and distributed sync. The receiving process also
  needs the same compiled ruleset and listener modules loaded, since the function
  references resolve against them.
* **Performance is measured by shape, and only along the axes the suite covers.**
  `mix bench` (`bench/run.exs`) reports the empirical exponent rather than a wall-clock
  number, so a reintroduced quadratic shows up as `~n^2` instead of as a figure nobody has
  a baseline for.

  A first profiling pass found three quadratics in the size of a single join key's bucket
  and fixed all three: `Rete.Agenda` became buckets by sort key instead of one sorted list,
  each bucket became an ordered multiset instead of a list, and `insert/3` and `retract/3`
  stopped appending to their op accumulator once per fact. Inserting 4,000 facts under one
  key went from 250 ms to under 10 ms.

  A second pass added the scenarios that pass could not see, and found five more. All five
  are fixed:

  | scenario | was | now | fix |
  |---|---|---|---|
  | two rules concluding the same fact | `~n^1.93`, 193 ms | `~n^0.9`, 6 ms | the `inserters` index, §4 |
  | filling one collection behind a live token | `~n^2.37`, 48 ms | `~n^0.9`, 0.6 ms | the stored list *is* the binding, §5 |
  | filling one collection, no token yet | `~n^1.99`, 14 ms | `~n^1.0`, 0.7 ms | the same |
  | filling one collection one member at a time | `~n^1.78`, 31 ms | `~n^1.1`, 4 ms | the same; this is the shape batching cannot hide |
  | an unkeyed negation taking n blockers | `~n^1.72`, 30 ms | `~n^1.1`, 5 ms | a plain negation is an emptiness edge, §5 |
  | cancel n pending activations of one rule | `~n^1.51`, 17 ms | `~n^1.1`, 8 ms | `Rete.Agenda` over `Rete.Bucket`, §7 |

  Each has a **control** beside it in the suite, because an exponent alone does not say
  which half of a scenario is slow. Two rules concluding the same fact used to run 37× the
  *disjoint* conclusion of the same two rules over the same fact count, and now runs level
  with it. The unkeyed negation runs against the keyed one; the collection runs at both
  batch shapes and at one member per call, which is the only one of the three that no
  amount of batching helps.

  The three collection rows are one fix, and it is the only one that changed what the
  engine guarantees. It withdrew a guarantee that should never have been made: collections
  were sorted so that their order, and not merely their membership, was a function of the
  fact set. Nothing in the contract asked for that, and it cost O(k) on every member change
  to provide. See `network.md` §3.

  Two of the fixes are indexes, and an index is a trade, not a free lunch. Maintaining
  `inserters` costs about 13% of a settling pass that never re-concludes anything, and
  making `Rete.Agenda.remove/2` O(1) costs about another 13% of one that never cancels
  anything. Both were measured by disabling the maintenance and re-running, not inferred.
  Firing 4,000 activations went from 10.5 ms to 13.9 ms across the two. That is the price
  of the table above.

  Still unmeasured: wide disjunctions, many rules over one fact type, and sessions large
  enough to matter for memory, not just time. Working-memory cost also grows with the
  **size** of a fact, not only the count: a bucket keys its multiset on the whole item, so
  every push and take hashes it. 500 facts at a 1-field payload cost 1.4 ms; the same 500
  at 512 fields cost 4.2 ms.

  One method note worth keeping: the first attempt fixed the **wrong** quadratic. Beta
  memory's append was real, and it had to go, but it was not what dominated. The agenda
  dominated instead, and an earlier version of this list had already named it. The tell: a
  query terminal, which has no agenda, was near-linear, while a production terminal was
  not. Split the measurement, before you believe an attribution.

  That mistake has now been made twice, in the other direction. This list previously read
  "filling one collection measures `~n^1.94`, because `insert_ordered/2` is O(k) per
  member" — a since-removed function that walked the group list to find where an arriving
  member sorted. A probe seemed to confirm it: feed the members in descending term order,
  making that walk a prepend, and the scenario goes linear. The attribution was still
  wrong. The fixture inserted `{:cust, 1}` **first**, which puts that token's `:left` op
  *behind* all n order ops in the queue, so every member arrived at a node with no tokens
  under the key and the collection was never read back. The scenario was not reaching the
  incremental path at all. Settle the token first and a second, independent quadratic
  appears. A control that agrees with the hypothesis is not a control; vary the thing the
  hypothesis says is irrelevant.

  A third variant of the same error, from the pass that fixed these. Keeping the group in a
  `:gb_trees` was supposed to make filling a collection cheap, since ordered insertion drops
  from O(k) to O(log k). On its own it made both collection scenarios **slower**, because
  reading a group back then has to materialise it, which a list did not need to do. Batching
  rescued the numbers by cutting read-backs from two per member to two per call, and the
  tree got the credit.

  It did not deserve it. The tree was answering the wrong question: the expensive thing was
  never the ordered insert, it was that the stored group and the emitted binding were two
  different values, so every change built one from the other. Dropping the sort — which the
  contract never promised — makes the stored list *be* the binding, and the tree, the
  materialisation and the batching-dependence all go away together. Filling a collection one
  member at a time went from 31 ms to 4 ms, on top of what batching had already done.

  Measure the fix, not just the bug. And when a fix needs a second fix to look good, check
  whether the first one was the right one.
