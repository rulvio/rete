# The engine

What runs the network `w2-network.md` describes. The companion to `w1-ir.md` (the
DSL front end) and `w5-observability.md` (listeners, inspection, the loop guard).

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

Clara propagates by **mutating a transient memory** while calling down the node tree,
then converting back to a persistent memory at the end of `fire-rules`. That duality is
why it needs an `ITransport` abstraction, four activation protocols, and seventeen
listener methods sprinkled through every node.

This engine runs a **flat propagation loop over an explicit work queue**. A node is a
function of state that returns the new state plus the work it produced, and the loop
does the walking:

```elixir
# lib/rete/engine/nodes.ex
handle(state, {op_kind, node_id, items}) :: {state, [op]}
```

Four consequences, all of which are load-bearing:

* **no transport abstraction** — it was indirection for a distributed transport that
  never shipped;
* **one immutable `Rete.Memory`** threaded through a fold, so a session is a *value*:
  holdable, comparable, forkable, sendable between processes with no coordination;
* **propagation is flat iteration**, so a cascade of any depth costs no stack;
* **events are emitted in exactly one place** — the loop — rather than in every node.
  That is what made the listener work in W5 cheap.

## 2. Two nested loops

```
insert / retract  ->  enqueue alpha ops  ->  drain
fire_rules        ->  drain, then: pop the most salient activation, run it,
                      insert what it returned, drain, repeat until the agenda is empty
```

**Propagation is drained to completion before the next activation fires.** A rule must
see a settled network or it could act on a half-built match.

`fire_rules/2` returns at **quiescence**: every rule whose left hand side holds has
fired, and nothing is still asserting anything whose support has gone. That is the point
at which a session is consistent, and it is the only state the public API ever hands
back.

### Ops

| op | carries | produced by |
|---|---|---|
| `{:left, node_id, tokens}` | tokens from a parent | any node propagating downstream |
| `{:right, node_id, elements}` | elements from an alpha | `Rete.Engine`, on insert |
| `{:left_retract, ...}`, `{:right_retract, ...}` | the same, going away | retraction |
| `{:retract_facts, node_id, facts}` | conclusions to take back | a `Production` whose token was retracted after it fired |
| `{:event, event}` | a listener event | any node with something to report |

The last two are the work a node cannot carry out where it happens: retracting has to
re-enter the **alpha** network, which only the engine can reach, and telling a listener
is not a node's business.

## 3. What travels

**`Rete.Element`** — a fact that matched one condition, plus the bindings that match
produced. Elements arrive from the right.

**`Rete.Token`** — a partial match: `:matches`, the `[{fact, node_id}]` behind it *in
order*, and `:bindings`, the variables bound so far. Tokens arrive from the left.

Both are compared **by value**. Two tokens over equal facts with equal bindings are the
same match whoever produced them, which is what makes retraction work when the term that
triggered it is a different term of the same value. Match *order* is part of a token's
identity: two tokens over the same facts in a different order are different matches.

**`Rete.Activation`** — a production node plus the token that satisfied it, plus the
salience and compile order it will be sorted by.

## 4. The five memories

```
elements    node_id => join_key => [Element]           right side of a beta node
tokens      node_id => join_key => [Token]             left side of a beta node
accum       node_id => join_key => group_key => [fact] what a collection gathered
insertions  node_id => token => [[fact]]               truth maintenance
facts       fact => count                              what the session holds
```

Three properties matter more than the shapes.

**Keyed by value, so removal must collapse.** A join key and a group key hold the
bindings they were built from. An entry left pointing at an empty leaf is not untidiness,
it is a leak that grows with the number of distinct entities the session has ever seen —
and `Rete.Engine.Nodes` depends on the collapse, because "no group" and "an empty group"
are different answers and only a level that really is gone may disappear.

**Multisets, not sets.** `facts` counts. Inserting the same fact twice and retracting
once must leave it present: two rules may each have concluded it, and one of them being
invalidated does not make it false. `elements` and `tokens` are lists for the same
reason, and are retracted one occurrence at a time.

**`insertions` is the provenance graph.** "This match at this production inserted these
facts", which read backwards is exactly the edge `Rete.Inspect.explain/2` walks. No
separate bookkeeping exists for explanation; there is nothing to keep in sync.

`root_seeded?` is the one field that is not a memory — see §6.

## 5. Node behaviour

Every clause of `Rete.Engine.Nodes` has the same shape: take the state and the
items, return the new state and the work produced.

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

**Every node must retract exactly what it propagated** — the same value, not something
equivalent, because downstream memories remove by value and a mismatch leaves a token
stranded forever, which then fires a rule whose support is gone.

The discipline that makes it hold: a node never propagates from what it was *handed*, it
propagates from what its memory says *after* the memory has been updated.
`Rete.Memory.remove_elements/4` and `remove_tokens/4` report the occurrences they
actually held, and only those are propagated onward. A retraction of something never
stored produces no downstream work at all. This is the single contract no end-to-end
property test can reach — every one of them still passes with the filtering removed — so
it is tested directly against the memory.

### A collection is one match, not many

An accumulate node emits the gathered **list** as a single binding. Change any member and
the list is a different value, so it is a different token: the old one is retracted, the
new one propagates, and truth maintenance replaces the conclusion. That is why a rule
over a collection fires once per group rather than once per gathered fact.

Elements are kept in term order rather than appended on arrival, so the same fact set
always produces the same list whatever order the facts arrived in, and a
retract-and-reinsert round trip restores it exactly. That is an implementation
guarantee — without it a rule that *returns* its collection would break order
independence — and not a contract. See `w2-network.md` §3.

## 6. The root token

Nothing binds before a rule's first condition, so a rule that opens with a negation, a
collection or a test has no element to build its first token from. A `RootJoin` does not
need one; a `Negation` hanging off the beta root has to pass *something* while nothing
matches, and an `Accumulate` there has to emit its collection to someone.

Classic Rete answers with a single empty token seeded at the root, and so does this. It
is planted at **state creation**, not on the first fact, because a rule whose whole left
hand side is an absence or an empty collection is true of the empty session and must be
able to fire before anything is inserted. `Rete.Memory.root_seeded?` makes it idempotent:
a second root token would give every such rule a second support that no retraction ever
clears.

It is machinery, not a match. `Rete.Inspect` never presents it as a fact.

## 7. Firing

Activations are ordered `{salience, internal_salience}` descending, then compile order
ascending. Compile order — not map order — is what makes two rules of equal salience fire
in the order they were written; a rules engine whose output depends on map iteration is
impossible to reason about.

`internal_salience` is the tier that makes an extracted negation helper fire before the
rule that negates its marker. Without it the negating rule observes an absence that had
merely not been computed yet, fires, and is retracted — a visible spurious activation.
It is reserved; a rule that sets it raises.

The agenda is **bucketed by sort key**, not a heap, because removal by value is the
common operation rather than an afterthought: an activation is a *pending* match, and the
facts behind it can be retracted before it fires. `Rete.Agenda.remove/2` reports whether
it found one, which is exactly the distinction a production needs on retraction — either
the match never fired and simply never will, or it fired and its conclusions have to be
taken back.

Every activation of one production shares a key — salience, internal salience and compile
order all come from the node, none from the match — so there are at most as many buckets
as there are production nodes, however many facts a session holds. One sorted list
instead would walk past every match already queued for the same rule on each insertion.

### Two matches of one rule

They fire in **arrival order**, and that runs deeper than the agenda. It holds because
each of these is arrival ordered, in turn:

* a bucket hands its items back in the order they were pushed (`Rete.Memory.Bucket`);
* a batch of items arriving at a node is split into join groups in the order each key
  first appeared, not in map order — `Enum.group_by/2` returns a map, and Elixir iterates
  one of up to 32 keys in term order and a larger one in an internal hash order, so
  taking that order would change a rule's firing sequence the moment a node saw its 33rd
  join key;
* the agenda appends within a bucket rather than inserting.

None of it changes what a session *concludes* — that is order independent, and the
property suite says so. It decides the order `:activation_fired` events arrive in, which
is what anyone reading a trace is relying on.

## 8. Truth maintenance

Facts a rule inserts are **logical**: they exist while the match that concluded them
does. Each insertion is recorded against its token, and retracting that token retracts
the facts, which may retract the support of other conclusions, cascading until it
settles.

This is why the right hand side inserts and never retracts. A rule says what follows from
a match; keeping that true as facts change is the engine's job. With no unconditional
insert there is no way to leave a conclusion behind whose support is gone.

### Support is well founded, not merely counted

A match that rests on the very fact it concludes would support that fact with itself: the
count never reaches zero, so the fact survives the retraction of everything the user ever
asserted and the memories behind it never drain.

```elixir
defrule symmetric({:edge, a, b}), do: {:edge, b, a}
```

One `{:edge, 1, 2}` concludes `{:edge, 2, 1}`, which concludes `{:edge, 1, 2}` right
back. So a conclusion the match already depends on is **dropped**: not inserted, not
recorded, no count bumped. The check runs only when the fact is already present — the
only way the loop can close — and walks the insertion records rather than the network.

The limit of deciding this at insertion time rather than by re-deriving on every
retraction: the dropped support is not reconsidered later. If the grounded route to a
fact goes away while the circular one would still have held, the fact goes with it.

## 9. Queries

A query terminal stores the tokens that reach it instead of activating. `Rete.Engine.query/3`
returns their `:bindings`, filtered by equality against the parameters given.
`Rete.Compiler` rejects at build time a parameter the left hand side does not bind on
every path, since it could never be satisfied.

A query reads the session as it stands, so one answered before `fire_rules/2` reports
what was true before the pending activations fired.

## 10. What is asserted about all of this

Facts alone are a weak lens. When a node propagates a token it had already propagated,
the duplicate fact collapses into a count bump in the multiset: `Rete.Session.facts/1`
looks perfect and the corruption surfaces much later, as a fact that survives the
retraction that should have removed it. The suite therefore asserts on
`session.state.memory`, and these four are the invariants that actually catch engine
bugs:

* **full drain** — retract everything, then every memory equals a **fresh session's**
  (`Rete.Session.new([Mod]).state.memory`). That pins both "drained" and "exactly one
  root token", which an emptiness check structurally cannot see;
* **support counting** — a fact concluded by exactly one match is held exactly once; two
  supports need two retractions and the first leaves the fact standing;
* **round trip** — insert X, fire, retract X, fire, compare against the state before;
* **order independence** — the same facts in any order, in any batching, give the same
  derived state, and any sequence of inserts and retracts leaves a session equal to one
  rebuilt from the surviving facts.

Plus one that no end-to-end property reaches, and so is tested against the memory
directly: **a memory reports the occurrences it actually held, not the ones it was asked
to remove**.

---

## 11. Known gaps

* **`well_founded/3` costs a pass over the insertion records.** Only when the concluded
  fact is already present, which is the only way the cycle can close, but a rule that
  keeps re-concluding what another rule concluded pays for it on every activation.
  Indexing that away was deferred.
* **A dropped circular support is not reconsidered.** See §8.
* **The loop guard counts activations, not activation-group transitions.** Clara's signal
  is better in principle — a ruleset that legitimately fires 50,000 activations in one
  settling pass is fine — but it misses a loop confined to a single salience level, which
  is the common runaway. See `w5-observability.md` §3.

  Resolved by not guessing. The default was 10,000 until `mix bench` reached it with
  4,000 facts through a three-rule chain — 12,000 activations, not a loop in sight — and
  the guard is now `:infinity` by default, the same opt-in call Clara makes. A count
  cannot separate a runaway from a large settling pass, so any default eventually fails
  correct code, and stopping part way through settling returns an answer that is wrong
  rather than late. The cost is that an oscillating ruleset now spins until interrupted;
  `Rete.Engine`'s loop guard section carries the numbers for choosing a cap where that
  matters.
* **No partial firing.** `fire_rules/2` runs to quiescence in the calling process. There
  is no fire-one-activation, no async, and no way to interrupt a settling pass other than
  the cycle cap.
* **Nothing is durable.** A session is an in-memory value; there is no serialization,
  checkpointing or distribution.
* **Performance has been measured in one dimension only.** A profiling pass found three
  quadratics in the size of a single join key's bucket and fixed them: `Rete.Agenda` is
  bucketed by sort key rather than held as one sorted list, `Rete.Memory.Bucket` replaced
  the list behind each key with an ordered multiset, and `insert/3` and `retract/3` no
  longer append to their op accumulator once per fact. Inserting 4,000 facts under one
  key went from 250 ms to under 10 ms; retracting 200 of them from a bucket of 8,000,
  from 108 ms to under 1 ms.

  `mix bench` (`bench/run.exs`) is what says so, and keeps saying so: nine scenarios at
  three sizes each, reporting the empirical exponent rather than a wall-clock number, so
  a reintroduced quadratic shows up as `~n^2` instead of as a figure nobody has a
  baseline for. Eight come out linear. The ninth does not, and is left in deliberately —
  filling one collection measures `~n^1.94`, because `Rete.Engine.Nodes.insert_ordered/2`
  is O(k) per member. A suite that only reported the good news would be worth less.

  Still unmeasured: wide disjunctions, many rules over one fact type, and sessions large
  enough to matter for memory rather than time. The fact-to-token index behind
  well-founded support is also still rebuilt on demand.

  A method note worth keeping. The first attempt fixed the **wrong** quadratic. Beta
  memory's append was real and had to go, but it was not what dominated — the agenda was,
  and an earlier version of this list had already named it. The tell was that a query
  terminal, which has no agenda, was near-linear while a production terminal was not.
  Split the measurement before believing an attribution.
