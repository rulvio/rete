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
insert / retract  ->  update memory, enqueue alpha ops. Nothing else.
fire_rules        ->  drain, then: pop the most salient activation, run it,
                      insert what it returned, drain, repeat until the agenda is empty
```

**`fire_rules/2` is the only entry point that propagates.** `insert/3` and `retract/3`
record the fact and queue the work. `new/1` queues the root token the same way. So a state
nobody has fired holds facts, and no matches, tokens or activations.

Two things follow. A caller may batch any number of inserts and retractions for the cost of
one settle. And a query reads propagated state, so it answers **as of the most recent
fire**. On a session that never fired that is `[]`. On one that fired and then received an
insert, it is the previous answer, which is stale rather than empty. The stale case is the
one that catches people out, because an empty result at least looks wrong.

`Rete.Session.settled?/1` reports an empty queue. A query does not raise on a full one,
because the last settled answer is a true answer about some state of the session.
`Rete.Inspect.why_not/2` and `collection/3` do raise, because they answer *why* a rule did
not match, and an answer about the wrong state of the session is false to that question.
See §12.

A fire **coalesces the queue before it drains it**, so work that spans several calls reaches
a node as one batch. `insert/3` already merged the ops of its own call, and nothing used to
span calls because each call drained. Now they queue, so a caller feeding one fact at a time
would otherwise hand a node one item per call. With the merge, 1,000 single-fact calls cost
what one call carrying 1,000 facts costs. This is safe to run over the whole queue only at
that point. The queue then holds nothing but `{direction, node, items}`. Nodes produce
`{:event, ...}` and `{:retract_facts, ...}` during the drain.

**A node's merge window closes when the opposite direction reaches that node.** Merging
moves an op back to where its target first appeared, and the two directions do not commute.
`Rete.Memory.remove_elements/4` removes only the occurrences it holds and drops the rest,
which is the retraction rule in §5. So an op moved back past its own inverse can lose a
retraction: the fact leaves working memory, the element stays in the node, and no later fire
reaches it, because the queue is empty and `settled?/1` answers `true`. The window rule
refuses that move, and asks nothing of how the queue was built. One `insert/3` or
`retract/3` call queues one direction, so a batch of any size still merges to one op. Only a
caller that alternates the two directions on one node across calls gets more than one, and
it gets one per run.

Where the caller put its call boundaries is therefore not part of what a session means. Any
sequence of inserts and retractions batched before one fire settles where firing after every
call settles. Queuing an insert and then a retract of the same fact drains to a net no-op.
`Rete.PropertyTest` pins the general statement over random sequences.

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

## 4. The five memories, and one index over them

```
elements    node_id => join_key => Bucket of Element     right side of a beta node
tokens      node_id => join_key => Bucket of Token       left side of a beta node
accum       node_id => join_key => group_key => [member] what a collection gathered
insertions  node_id => token => [[fact]]                 truth maintenance
facts       fact => count                                what the session holds

inserters   fact => {node_id, token} => count            `insertions`, reversed
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

`inserters` is that same relation indexed the other way, and the one derived thing in here.
Both its readers ask "which matches inserted *this fact*". `well_founded/3` asks on every
conclusion already present, and `Rete.Inspect.derivations/2` asks per fact. Answering from
`insertions` costs a pass over every insertion record, which made two rules concluding one
fact quadratic. Two rules concluding one fact is the ordinary shape of truth maintenance,
not a pathology.

**It is built on first use.** A ruleset where no rule re-concludes never reaches for it, and
maintaining it on every insertion would cost about 13% of a settling pass for nothing. So it
stays `nil` until `Rete.Memory.index_inserters/1` builds it in one pass. After that
`add_insertion/4` and `take_insertion/3` keep it in step, and a property rebuilds it the
slow way and compares.

`nil` also stands for "emptied", since an index and its absence are the same claim when it
holds nothing. Collapsing them is what lets a fully drained session compare equal to a fresh
one. It is a multiset keyed on `{node_id, token}`, so it does not depend on the order the
session reached it in. Being a cache, it is left out of `dump/1`.

`root_seeded?` is the one field that is not a memory — see §6.

## 5. Node behavior

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

A collection's *order* is therefore not a function of its fact set. Its *membership* is.
The engine used to sort to make the order one too, which nothing had asked for and every
collection paid for. See `network.md` §3, and `docs/dsl.md` for the rule it puts on rule
authors.

## 6. The root token

Nothing binds before a rule's first condition. So a rule that opens with a negation, a
collection, or a test has no element to build its first token from. A `RootJoin` does not
need one. But a `Negation` hanging off the beta root has to pass *something* while nothing
matches. An `Accumulate` there has to emit its collection to someone too.

Classic Rete answers this with a single empty token, seeded at the root, and this engine
does the same. `new/1` **queues** that token, and the first `fire_rules/2` plants it. A rule
whose whole left hand side is an absence, or an empty collection, is true of the empty
session. It must be able to fire before you insert anything. It can, because firing drains
the queued seed before it fires anything.

`Rete.Memory.root_seeded?` makes seeding idempotent. A second root token would give every
such rule a second support, and no retraction would ever clear it.

It is machinery, not a match. `Rete.Inspect` never presents it as a fact.

### A production with no conditions

A production that declares nothing is the degenerate case of all of this. Its terminal
hangs straight off the beta root, so the seeded token is its whole match. It therefore gets
exactly one activation, on the first fire.

Its conclusion rests on the root token, which no retraction reaches. So it is the one
conclusion that survives retracting every fact the user asserted. That does not break the
guarantee in §8. The conclusion is still well founded: the root token is its support, and
that support never goes.

A query written the same way holds that one token and answers one row, in every session
after a fire. `docs/dsl.md` states both for rule authors, and `Rete.EngineTest` pins them
under "the root token".

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

Batching is not a micro-optimization. A node's per-call work is not all per item — it
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
task costs about 3.5 µs per activation, so parallelizing cheap bodies is a large net loss.
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
  token.** Adding is O(1), because the stored list is the binding and a member is
  prepended. Removal walks to the member. An `AccumulateJoin` re-decides membership per
  token from the bindings its alpha produced, so it cannot share one value the way a plain
  collection does. Neither is quadratic in a session, and both are measured.

  A rule that *reduces* its collection pays a further O(k) per firing. That cost is in the
  body, not the engine. This list used to put it in the engine, and argued for an accumulator
  on the strength of it. Both were wrong, and §13 carries the correction: what the measurement
  actually shows, why batching removes most of it, and why a rule that folds and concludes a
  scalar already covers the case without changing what `defrule` accepts.

* **An unchanged conclusion is retracted and re-asserted.** When a token is replaced, the
  engine retracts what the old token concluded and inserts what the new one concludes. It
  does not compare them. So a rule whose conclusion drops the part of the match that changed
  re-asserts an identical fact, and every rule beneath it re-fires.

  ```elixir
  defrule known({:cust, id, _version}), do: {:known, id}
  ```

  Over 2,000 updates to one customer, `{:known, 1}` is asserted throughout and never absent
  from `Session.facts/1`. Every rule in the chain below still fired 2,001 times. The cost is
  linear in the depth of that chain: 4.7 ms for the rule alone, 9.1 ms with one consumer,
  18.5 ms with three.

  Nothing observable is wrong, because a body is pure and returns facts. The waste is the
  firing and the listener churn. A fix has to defer a production's retraction to the end of
  the cycle and cancel it if the same fact is re-concluded, which is a change to truth
  maintenance rather than a local one. It is the largest unclaimed win left.

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
* **An unfired session answers no query. This diverges from Clara.** Clara's
  `test_negation/test-simple-negation` queries `empty-session`. Nobody inserted into it,
  and nobody fired it. The test expects one row. Clara plants the root token when it builds
  the session. This engine answers `[]` there.

  The two agree everywhere else in that test. Eleven of its sessions receive an insert, and
  the test fires all eleven before it queries them. So deferring insert and retract costs
  nothing against Clara. Only the untouched session differs.

  The trade is deliberate. Propagating at construction meant a caller saw queued
  activations on a session they never touched. It also meant a listener could never
  observe the matching `:activation_added`. `Rete.Engine.State` starts with no listeners,
  and `Rete.Session.with_listener/3` can only attach afterward. One entry point that
  propagates is worth more than agreeing with Clara on the empty case. `Rete.BehaviorTest`
  records the divergence where it pins the Clara case.
* **No partial firing.** `fire_rules/2` runs to quiescence in the calling process. There
  is no fire-one-activation option, no async variant, and no way to interrupt a settling
  pass other than the cycle cap.
* **Nothing reports what *would* activate before it activates.** Working out which rules a
  queued fact satisfies means matching it, and matching before a fire is exactly the work
  this design moved into the fire. A function that answered it would do that work twice, or
  do it early and throw it away when the caller inserted one more fact.

  So the engine reports two things instead, and neither costs anything.
  `Rete.Session.settled?/1` says that work is waiting, and not what it is.
  `Rete.Listener` reports each activation as it is added and as it fires, which is the same
  information at the moment it stops being a guess. `Rete.Inspect.why_not/2` answers the
  question after the fact, on a settled session.

  `Rete.Session.pending/1` was the function that tried the other way, and 0.5.0 removed it.
* **No checkpoint or migration API, but a session is trivially serializable.** A session
  holds no PID, ETS table, or other process-local handle. It is plain data, plus function
  references into the ruleset and listener modules that built it. Because of this,
  `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` round-trip a whole session,
  including its compiled network, with no wrapper needed. What is still missing: a
  checkpoint API, versioned migration, and distributed sync. The receiving process also
  needs the same compiled ruleset and listener modules loaded, since the function
  references resolve against them.
---

## 13. Performance

`mix bench` (`bench/run.exs`) reports the empirical exponent of each scenario, not a
wall-clock number. A reintroduced quadratic then shows up as `~n^2`, instead of as a figure
nobody has a baseline for.

### What two passes found

The first pass found three quadratics in the size of one join key's bucket. `Rete.Agenda`
became buckets by sort key instead of one sorted list. Each bucket became an ordered
multiset instead of a list. `insert/3` and `retract/3` stopped appending to their op
accumulator once per fact. Inserting 4,000 facts under one key went from 250 ms to under
10 ms.

The second pass added the scenarios the first could not see, and found five more:

| scenario | was | now | fix |
|---|---|---|---|
| two rules concluding the same fact | `~n^1.93`, 193 ms | `~n^0.9`, 6 ms | the `inserters` index, §4 |
| filling one collection behind a live token | `~n^2.37`, 48 ms | `~n^0.9`, 0.6 ms | the stored list *is* the binding, §5 |
| filling one collection, no token yet | `~n^1.99`, 14 ms | `~n^1.0`, 0.7 ms | the same |
| filling one collection one member at a time | `~n^1.78`, 31 ms | `~n^1.1`, 4 ms | the same, and the shape batching cannot hide |
| an unkeyed negation taking n blockers | `~n^1.72`, 30 ms | `~n^1.1`, 5 ms | a plain negation is an emptiness edge, §5 |
| cancel n pending activations of one rule | `~n^1.51`, 17 ms | `~n^1.1`, 8 ms | `Rete.Agenda` over `Rete.Bucket`, §7 |

Each has a **control** beside it in the suite, because an exponent alone does not say which
half of a scenario is slow. Two rules concluding the same fact used to run 37× the
*disjoint* conclusion of the same two rules, and now runs level with it. The unkeyed
negation runs against the keyed one. The collection runs at both batch shapes and at one
member per call.

The three collection rows are one fix, and the only one that changed what the engine
guarantees. See `network.md` §3.

### What is left in a collection is the rule body

That fix moved the cost rather than removing all of it, and this section claimed otherwise
for several passes. The claim was that a rule which only reduces a collection — `orders`
then `length(orders)` — still pays to build the list. It does not, and has not since the
stored list became the binding.

Inserting members one at a time and firing after each, with the same rule written twice:

| n | body reads the collection | body ignores it | the body's share |
|---|---|---|---|
| 1,000 | 3.4 ms | 2.6 ms | 0.7 ms |
| 2,000 | 8.4 ms | 5.2 ms | 3.2 ms |
| 4,000 | 26.9 ms | 10.0 ms | 16.9 ms |

The middle column is the engine, and it is linear: each doubling costs exactly 2×. The right
column is the body, and it grows about 5× per doubling, at or a little above the 4× that n²
predicts. At 4,000 members the body is nearly twice the engine.

The body runs n + 1 times, once per member and once for the empty collection, with no
activation cancelled. Each run walks the whole list, so the body traverses about n²/2 cells
— 8M at n = 4,000, which is the 16.9 ms above at roughly 2 ns a cell.

**That count is a function of how members arrive, not of how many there are.** Alpha batching
(§7) folds every member arriving in one `insert` call into one group change, so the rule fires
once per call. The same 4,000 members, and the concluding-a-list shape below alongside:

| members per call | firings | reads it | ignores it | the body's share | concludes the list |
|---|---|---|---|---|---|
| 1 | 4,001 | 27.1 ms | 10.0 ms | 17.1 ms | 408 ms |
| 10 | 401 | 4.6 ms | 3.3 ms | 1.3 ms | 43 ms |
| 100 | 41 | 3.0 ms | 2.8 ms | 0.2 ms | 6.8 ms |
| 1,000 | 5 | 2.9 ms | 3.0 ms | 0.0 ms | 3.7 ms |
| 4,000 | 2 | 3.4 ms | 3.2 ms | 0.2 ms | 3.3 ms |

Both quadratics are O(n²/b) for a batch of b, and both are noise by b = 100. Only a caller
that must fire per member pays either.

The last column is the shape to warn authors about, because it is 15× the reducing form at
b = 1 and nothing in the DSL discourages it. A body that puts the collection **into** its
conclusion makes `Memory.add_fact/2` hash a fact that grows with the group, once per change.
That is inherent to concluding a growing value, not a defect in the collection. See
`docs/dsl.md`.

### What an accumulator would and would not buy

The engine has no collection gap left against Clara at these shapes. What an accumulator —
a `defrule` that could say *count* rather than *gather, then count* — would add is narrower
than earlier drafts of this section claimed.

It would **not** reduce how often a rule fires. Clara's `right-activate-reduced` propagates
whenever the reduced value differs from the previous one, and a count differs on every add,
so `acc/count` re-fires as often as gathering does. What changes is what the token carries: a
scalar the engine maintained once per member at O(1), rather than a list the body folds at
O(k) per firing. That is the body's share above, and nothing else.

For collect-all it buys nothing at all, in either engine. Clara's add path is incremental —
it folds new facts into the previous reduced value rather than re-reducing — but for `acc/all`
the reduced value *is* the list, so it changes on every member and the body receives the whole
thing. Retraction is worse there than here: `drop-one-of` walks the collection twice and
rebuilds it, where `List.delete/2` walks once and shares the tail past the removal. `min` and
`max` carry no `retract-fn` and re-reduce the group.

`min` and `max` are the one case that would also cut firings, because a new member usually does
not move the answer and the differs-from-previous check suppresses the propagation.

So the case for an accumulator is an intersection of two conditions: a caller that fires per
member, and a reduction to a scalar. That is the 17 ms cell above. Everywhere else, batching
or the shape of the reduction has already taken it.

And that case is already expressible, without extending the DSL. A rule that folds and
concludes **is** the accumulator:

```elixir
defrule order_count({:cust, id}, os = [{:order, id, _a}]), do: {:order_count, id, length(os)}
```

Every other rule then matches `{:order_count, id, n}` and binds a scalar. The fold happens
once no matter how many rules consume it, exactly as a shared accumulate node would, and the
engine stays a rule engine rather than growing an aggregate library.

One thing that composition does not recover, and it is not an argument for accumulators.
Clara compares the reduced value **at the accumulate node**, upstream of any production, so
an unchanged `min` moves nothing below it. The derived-fact version compares nothing: the
producing rule re-fires, retracts its old conclusion and asserts an identical one, and every
rule beneath it re-fires. Measured with a `max` that never moves over 4,000 members, the two
rules below it each fired 4,001 times.

That is the general gap recorded in §12, not a collection problem. Closing it would make the
derived fact strictly better than an accumulator, because it would also be shared, pure, and
quiet.

### Indexes are built on first use

Two of the fixes are indexes, and an index charges every operation for a benefit only some
workloads collect. Maintaining `inserters` cost about 13% of a settling pass that never
re-concludes. Making `Rete.Agenda.remove/2` O(1) cost about another 13% of one that never
cancels. Both were measured by disabling the maintenance and re-running, not inferred.

Both are built on first use now. A session that only inserts never takes from a beta memory
and never cancels an activation, so no `Rete.Bucket` builds its `:counts`. A ruleset where
no rule re-concludes never reaches `well_founded/3`, so `inserters` stays `nil`. Neither is
asymptotically worse for a session that does retract.

| insertion-only workload | eager indexes | built on first use |
|---|---|---|
| insert 4,000, one conclusion each | 12.3 ms | **8.5 ms** |
| insert 4,000 through a three-rule chain | 38.2 ms | **25.2 ms** |
| 4,000 activations pending at once, then fire | 12.1 ms | **8.6 ms** |

### Compile time

Disjunctions hold to the claim `network.md` §5 makes. A rule with d disjunctions of three
branches compiles to `3d + 1` beta nodes. That is linear in d, where flattening the left
hand side to disjunctive normal form would give `3^d` paths — 25 nodes at d = 8, against
6,561. `Rete.DisjunctionTest` pins the node count rather than the wall clock, since the
claim is about work. Width is bounded instead of linear: compile time is roughly quadratic
in one gate's branch count, and `Rete.DSL.Normalize` refuses a gate past 256, so the worst
case is 7.3 ms once.

Many rules over one fact type was hiding two compile-time quadratics rather than a runtime
one. Firing is linear in the rule count, and inherently so, since every fact is offered to
every alpha its type routes to. `BetaGraph` found a shareable node by scanning every child
of every parent, and r rules that share nothing all hang off the root. `link/3` then
appended to that child list, which is O(children) per node added. Sharing is an index now,
and children are stored newest first and reversed by `children/2`. Compiling 1,024 rules
over one fact type went from an extrapolated ~225 ms to 7.7 ms.

### Queries

A query stores its matches under one key and filters them on the way out, so a filter that
returns one row costs what returning every row costs. `Rete.Ruleset.index/2` declares key
sets to bucket them by, and `Rete.Engine.Nodes` keeps one store per declared set under
`Rete.Memory.index_id/2`. `Rete.Engine.query/3` then reads the largest declared set the
filter covers.

| 200 calls, 4,000 matches, one row returned | |
|---|---|
| no index | 97 ms |
| `index :rows, [:cid]` | **0.07 ms** |

Per call that is 0.3 µs, against Clara's 0.5 µs on the same probe. Flat in the match count,
where the scan is linear in it.

An index buys that with write cost, one bucket entry per match per declared set. Over 4,000
facts reaching a query node:

| | insert | retract |
|---|---|---|
| no index | 2.4 ms | 10.0 ms |
| one index | 3.0 ms | 16.5 ms |
| three indexes | 4.6 ms | 28.4 ms |

Retraction pays more than insertion, because taking from a bucket is what builds its
`Rete.Bucket` index. Both stay linear in the fact count.

In reads, an index costs about three to five unindexed calls to carry through a load, and
about twenty-five to thirty-five if the session is also fully drained. It saves nearly the
whole of each read it serves, so it pays for itself quickly on a session that accumulates
and is queried, and slowly on one that churns. Declaring three indexes to serve a query
nobody filters selectively is a straight loss.

The unbucketed store stays whether or not an index exists. `Memory.all_tokens/2` unions a
node's buckets in map order, so an unfiltered query read out of an index would order its
rows by binding value rather than by arrival. `Rete.Inspect` also counts a node's tokens by
its own id.

**Indexing by default was measured and rejected**, so that it is rejected on evidence rather
than reproposed on intuition. Over 4,000 matches at a query binding a 50-value field, a
20-value field and a unique id — which is what a real query looks like:

| | insert | retract | memory | buckets |
|---|---|---|---|---|
| no index | 2.3 ms | 11.1 ms | 1,169 KB | 1 |
| one composite over all three | 4.9 ms | 13.5 ms | 2,121 KB | 4,001 |
| one index per binding | 5.9 ms | 26.4 ms | 2,133 KB | 4,071 |

Both double the writes and the memory. The composite earns almost none of it back, because
`usable_index/2` needs the filter to cover the whole key set, so it serves only a filter
naming every binding — which returns one row and is the rarest call anyone makes.

The cost is cardinality, not indexing. An index over a unique field is one bucket per row,
and most queries bind at least one unique field. A default cannot know which bindings
partition usefully, and the ones that do not are exactly where an index costs most and
returns least. That knowledge only exists in the ruleset author's head, which is why
`index/2` asks for it.

Clara reaches the same place from the opposite direction. Its query params *are* its node's
join keys, so its lookup is a map fetch — but the params are mandatory and exact, and it
cannot filter partially at all. Declaring an index here constrains nothing: every filter
still works, indexed or not.

### Memory

Measured with `:erts_debug.size_shared/1`, which counts a shared subterm once. That is the
honest measure for a structure that shares as heavily as this one.

| shape | 1,000 facts | 8,000 facts | per fact |
|---|---|---|---|
| two-condition join | 533 KB | 4,275 KB | 546 B, unchanged across 8× |
| one collection | 90 KB | 359 KB (4,001) | ~91 B |

A session that inserts n facts and retracts them all comes back to **184 bytes**, whatever
n was. `inserters` measures zero in both shapes, since neither ruleset re-concludes.

Two cautions. Per-field figures double-count, because a fact term is shared between
`elements`, `tokens`, `insertions` and `facts`, so only the totals are honest. And cost
grows with the **size** of a fact as well as the count, since a bucket keys its multiset on
the whole item: 500 facts cost 1.4 ms at a 1-field payload and 4.2 ms at 512 fields.

### Three wrong attributions

Every quadratic here was first blamed on the wrong thing. The first attempt blamed beta
memory's append, which was real but not dominant — the agenda was. The tell: a query
terminal, which has no agenda, was near-linear while a production terminal was not. The
second blamed `insert_ordered/2` for the collection, and a probe agreed: feed members in
descending order, making that walk a prepend, and the scenario goes linear. The fixture was
hiding the real cause, because it inserted the token last and so never read a group back.
The third credited a `:gb_trees` group for a win that batching had delivered, when the tree
had in fact made both collection scenarios slower on its own.

Three rules come out of that. Split the measurement before believing an attribution. A
control that agrees with the hypothesis is not a control — vary what the hypothesis says is
irrelevant. And when a fix needs a second fix to look good, check whether the first one was
right.
