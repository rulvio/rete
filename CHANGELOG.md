# Changelog

All notable changes to `rete` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.0

`fire_rules/2` is now the only call that propagates. **This release has breaking changes.**

### Changed

* **`insert/2` and `retract/2` no longer propagate.** They record the fact and queue the
  work. `fire_rules/2` drains that queue, matches everything waiting, runs the rules that
  match, and returns at quiescence.

  A session you have not fired holds facts and nothing else. `Rete.Session.facts/1` still
  answers, because working memory is updated at once. Nothing else does: no rule is
  activated, and **a query answers nothing until you fire**.

  Two problems drove this. Building a session queued activations before the caller had done
  anything, so `pending/1` was non-empty on a session nobody had touched.

  A listener could never observe those activations either. `Rete.Engine.State` starts with
  no listeners, and `Rete.Session.with_listener/3` can only attach afterward. So
  `:activation_added` went to nobody, and a listener later saw `:activation_fired` for a
  rule it never saw added.

  Batching is the other gain. Any number of inserts and retractions now cost one settle.

* **`Rete.Session.pending/1` is removed.** `fire_rules/2` returns at quiescence and nothing
  propagates before it, so the function had no state left in which it could answer anything
  but `[]`. `Rete.Activation` no longer reaches the public API. Use `Rete.Listener` to
  observe activations.

* **One deliberate divergence from Clara.** Clara's
  `test_negation/test-simple-negation` queries a session that was never inserted into and
  never fired, and expects one row. Clara plants the root token when the session is built.
  This engine answers `[]` there. Every other session in that test is fired before it is
  queried, and those cases agree exactly. See `docs/design/engine.md` §12.

### Migration

Add a `fire_rules/2` before any query that ran against an unfired session:

```elixir
# before
session |> Session.insert(facts) |> MyRules.some_query()

# after
session |> Session.insert(facts) |> Session.fire_rules() |> MyRules.some_query()
```

Replace `Session.pending/1` with a listener:

```elixir
session
|> Session.with_listener(Rete.Listener.Collect, [])
|> Session.fire_rules()
|> Rete.Listener.Collect.by_tag(:activation_fired)
```

## 0.4.0

Node sharing now reaches across module boundaries. Composing rulesets costs what writing
them in one module costs.

### Performance

* **Rulesets in separate modules now share nodes.** A condition written in two modules used
  to compile to one alpha node per module, so a fact was matched against it once per
  module. It now compiles to one node, matched once, feeding every rule below it. Every
  beta join under that alpha is shared too.

  The split was there because an *unqualified* call hashes as its bare name. Two modules
  that import a different `ok?/1` and both write `{:bar, amt} when ok?(amt)` produce one
  code for two functions, so the compiler kept every cross-module code apart rather than
  tell a safe case from an unsafe one.

  `Rete.DSL.Codegen` now answers that question while it still holds the AST and the
  caller's environment, and records the answer in `Rete.IR.Expr`'s new `:share` field.
  `Rete.Compiler.disambiguate_codes/1` splits only the codes that field refuses.
  An imported call, a local call, and a compound negation marker are still kept apart. A
  plain pattern, a literal guard, and a qualified call are shared.

  This changes the shape of a network built from more than one module. It changes no
  result: the same facts fire the same rules and conclude the same facts either way.

  Measured over k modules writing the same two conditions:

  | k modules | alpha nodes | join nodes | matches per fact |
  |---|---|---|---|
  | 1 | 2 | 2 | 1 |
  | 8 | 2 | 2 | 1 |
  | 32 | 2 | 2 | 1 |

  Each of those was `k + 1`, `2k` and `k` before. A condition that still refuses to share
  keeps the old shape, which is what the new `mix bench` scenario contrasts against.

* `mix bench` grew from seventeen scenarios to eighteen. The added one matches 200 facts
  against the same condition in k modules, with nothing firing, so it measures matching
  alone. It is flat from k=4 to k=32. All eighteen are linear.

### Changed

* `Rete.IR.Expr` gains `:share`, and it defaults to `false`. Internals are not covered
  by semantic versioning — see "What is public" in the README.
* `Rete.DSL.Codegen.alpha_expr`, `test_expr` and `join_filter_expr` each take the
  caller's `Macro.Env` as a new first argument. They are now `/6`, `/3` and `/4`.

### Fixed

* The README claimed every `mix bench` scenario was linear "except one", and pointed at
  `docs/design/engine.md` §12 for it. No scenario has been superlinear since 0.3.0, whose
  own entry records that all seventeen were linear, and §12 lists design gaps rather than a
  measurement. The README also listed "many rules over one fact type" as unmeasured, which
  a 0.3.0 scenario already covers.
* `mix.exs` grouped the docs under `Rete.Memory.Bucket`, which does not exist. The module
  is `Rete.Bucket`, and it was the one module rendering with no group on hexdocs.
* The README omitted `Rete.Inspect.query_plan/3` from both its public API table and its
  list of what `Rete.Inspect` offers.
* Two section cross-references pointed at the wrong section: `Rete.IR` cited `ir.md` §2 for
  the "alpha matches any type" rule, which is §4, and `engine.md` cited `network.md` §3 for
  the no-DNF claim, which is §5.
* `ir.md` §8 still described the pre-0.4.0 rule, that every code two modules contributed
  was qualified.

None of these is a behavior change.

## 0.3.0

A performance pass. Six quadratics removed, and three orderings changed.

### Changed

Three orderings moved. Every one of them was documented as **unspecified** before this
release, so none was a promise. Each was costing real time to hold steady.

* **A collection gathers in reverse arrival order, and does not sort.** The same facts fed
  in a different order now produce a different list, and a member retracted and reinserted
  comes back at the front. What a collection *holds* is still a function of the fact set.
  Sort in the right hand side if the order matters. See `docs/design/network.md` §3.
* **Query rows follow the order the facts arrived.** `Rete.Session.query/3` no longer sorts
  its result. The *set* of rows never varies, and one feed always answers the same way.
* **A rule reached by two routes within one `insert` call** now sees all of one route's
  matches before any of the other's, instead of interleaving them fact by fact. A rule's own
  matches still arrive in fact order. `{:propagated, ...}` events coarsen with it: fewer
  events, larger counts, same shape.

### Performance

`mix bench` grew from nine scenarios to seventeen. The eight added cover the shapes the
original suite could not see, and each has a control beside it. All seventeen are linear.

| scenario | was | now |
|---|---|---|
| two rules concluding the same fact | `~n^1.93`, 193 ms | `~n^0.9`, 6 ms |
| filling one collection behind a live token | `~n^2.37`, 48 ms | `~n^0.9`, 0.6 ms |
| filling one collection, no token yet | `~n^1.99`, 14 ms | `~n^1.0`, 0.7 ms |
| filling one collection one member at a time | `~n^1.78`, 31 ms | `~n^1.1`, 4 ms |
| an unkeyed negation taking n blockers | `~n^1.72`, 30 ms | `~n^1.1`, 5 ms |
| cancel n pending activations of one rule | `~n^1.51`, 17 ms | `~n^1.1`, 8 ms |

Compiling 1,024 rules over one fact type went from an extrapolated ~225 ms to 7.7 ms. Beta
node sharing is an index now, rather than a scan of every child of every parent.

Sessions that only insert got about 30% faster. The two indexes that make retraction cheap
are built on first use, so a session that never retracts never pays for them.

Gathering into a collection is linear. What a collection costs after that depends on how
members arrive, because everything inserted in one call is one change. Over 4,000 members
arriving one per call, a rule that reduces its collection costs 27 ms, and one that concludes
a fact **holding** the collection costs 408 ms. Arriving a hundred per call, the same two cost
3.0 ms and 6.8 ms. Batch inserts where you can. See `docs/dsl.md`.

`docs/design/engine.md` §13 carries the measurements, the trades, and the three wrong
attributions made along the way.

### Added

* `index/2`, which declares how a query's matches are bucketed. A filter covering a declared
  key set reads one bucket instead of every match. Measured at 4,000 matches with one
  returned: 200 calls take 97 ms unindexed and 0.07 ms indexed.

  ```elixir
  defquery flagged_for({:flagged, cid, tid, amt}), do: {cid, tid, amt}

  index :flagged_for, [:cid]
  index :flagged_for, [:cid, :tid]
  ```

  `[:cid, :tid]` is one index over both bindings. Two indexes are two lines. A declaration
  may come before or after its query.

  **An index changes speed, not results.** Every filter works, indexed or not, and returns
  the same rows in the same order. It declares no parameters and permits nothing — the
  caller may still filter on any bound variable. Declaring none is the default, and a query
  without one behaves exactly as before.
* `Rete.Inspect.query_plan/3`, which reports the index a filter would use, or `:scan`. A
  declared index nothing matches is otherwise silently no faster.
* `Rete.Bucket`, the tombstoned ordered multiset behind both working memory and the agenda.
  Internal.
* `Rete.DisjunctionTest` and `Rete.CanonTest`. The first pins the compiler's claim that it
  never flattens a left hand side to disjunctive normal form, and the 256-branch cap, which
  had no test in either direction.

### Fixed

* The options map on `defrule` and `defquery` refused nothing it did not understand, so
  `%{saliance: 10}` was silently ignored. Unknown keys now raise. This can break a ruleset
  that passes a stray key.
* The README claimed no profiling pass had been done and no benchmark suite existed. Both
  were false.
* `docs/design/engine.md` attributed the collection quadratic to a walk that a control had
  seemed to confirm and had not.

## 0.2.0

Documentation and a dependency bump. No change to the DSL, the compiler or the engine.

### Documentation

* The whole prose surface rewritten in an ASD-STE100-influenced style: the README,
  `docs/dsl.md`, `docs/design/*.md`, and every `@moduledoc`, `@doc`, `@typedoc` and
  comment in `lib/`. Short sentences, active voice, no semicolons, no phrasal verbs.
  Every technical fact, hedge and caveat carries over unchanged — only the sentence
  structure does.
* Two stale claims in the README's Limitations section corrected. Neither is a
  behavior change; both describe what 0.1.0 already did.
  * "No parallel or async rule evaluation" was wrong: `fire_rules/2`'s `:concurrency`
    option already runs one activation group's rule bodies on tasks, and has since
    0.1.0.
  * "No durability" overstated the gap. A session holds no PID, ETS table or other
    process-local handle, so `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1`
    round-trip a whole session, including its compiled network, as long as the
    receiving process has the same compiled ruleset and listener modules loaded.
    There is still no checkpoint API, no versioned migration and no distributed sync.

### Dependencies

* `taxo` bumped to `~> 0.2.0`. A cyclic derivation passed to `derive/2` now raises
  `Taxo.CyclicDerivationError`, carrying `:child` and `:parent`, in place of a bare
  `RuntimeError`. `Rete.Taxonomy` already always builds a proper `%Taxo{}` before
  calling into it, so taxo's stricter argument typing changes nothing observable here.

## 0.1.0

First release. A complete forward-chaining Rete engine: the DSL front end, the network
compiler, the propagation loop, truth maintenance and the observability tools.

`0.1.0` rather than `1.0.0` deliberately. Everything documented works and is covered by
725 tests, but one part of the surface is known to be unsettled and is likely to change
without a major version: how a collection reaches per-group firing. See the known gaps
in `docs/design/`.

### The DSL

* `defrule/2` — a rule reads as a function: its arguments are the left hand side and its
  body is the right hand side.
* Fact patterns of any arity (`{:order, cid, amt}`, `{:tick}`), struct patterns
  (`%Order{id: id}`) and tagged maps (`%{__type__: :order, id: id}`).
* Fact bindings (`o = {:order, cid}`), per-condition guards
  (`{:order, amt} when amt > limit`) and rule-level guards.
* A variable shared by two conditions is a join; no join syntax.
* Collection bindings (`orders = [{:order, cid, amt}]`), collect-all, with the empty
  collection and collection-local variable rules of `docs/dsl.md`.
* Gates: `:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor`, nestable, with n-ary
  `xor` reading as "exactly one".
* Negation of a single condition, and of a conjunction — the latter extracted into a
  generated helper whose marker fact carries the bindings the negation is scoped by.
* `derive/2` and `underive/2` for fact-type hierarchies, applied by the alpha index.
* `defquery/2`. A query returns what its body computes, one result per match, and defines
  `<name>/1,2` in its own module so it is run by calling it —
  `MyRuleset.find_user(session, id: 1)`. Any binding can be filtered on; there is no
  parameter declaration.
* `%{salience: n}` for firing priority.
* Pinned values, module attributes and aliases resolved into a condition's identity, so
  that two conditions share a compiled node exactly when they behave the same.
* Compile-time errors, naming the rule and the variable, for: a guard reading a variable
  nothing binds, a left hand side that cannot be ordered, a binding that shadows an
  upstream variable, reading a collection-local variable outside its collection, a
  discarded (`_`-prefixed) variable read by a guard, a bound collection element, a
  production with no body, a production name declared twice in one module, the obsolete
  `params:` option, and two conditions reading the same module attribute at different
  values.

### The compiler

* Stable topological condition sort, so a rule may be written in the order it reads and
  a forward reference still compiles.
* Per-condition gate normalization — the left hand side is never flattened to whole-LHS
  DNF — with a 256-branch limit per gate.
* Alpha node sharing by expression code, and beta node sharing by equal sharing key
  **and** identical parent set (Clara issue 433).
* Cross-module expression code disambiguation, so two modules that write the same
  unqualified call cannot collapse onto one node.

### The engine

* Flat propagation loop over an explicit work queue; one immutable working memory, so a
  session is a value that can be held, compared, forked and sent between processes.
* Hash joins, expression joins, negation, negation joins, collections, collection joins,
  tests, productions and queries.
* Salience-ordered agenda with removal by value, so a match retracted before it fires
  never fires.
* Truth maintenance with **well-founded** support: a conclusion its own match rests on is
  dropped rather than supporting itself for ever.
* An **opt-in** loop guard. `:max_cycles` defaults to `:infinity`, so `fire_rules/2` runs
  to quiescence and an oscillating ruleset spins rather than raising; pass an integer to
  bound a call and it raises with the rules that fired most. A numeric default was tried
  and rejected: 10,000 was reached by 4,000 facts through a three-rule chain with no loop
  in sight, and a count cannot separate a runaway from a large settling pass, so any
  default eventually fails correct code. It counts **cycles** — one pass of the fire loop,
  which is one activation at the default concurrency and one whole activation group above
  it. An unrecognized value raises rather than quietly meaning no cap, which is what
  `max_cycles: nil` would do by accident of Erlang term order.
  `docs/design/observability.md` §3 has the numbers for picking one.
* **`:concurrency` and `:timeout` on `fire_rules/2`.** `concurrency: 1` by default, which
  fires one rule body at a time. Above `1` the bodies of one activation group run on
  tasks, and their conclusions are applied in group order. Worth raising only when a body
  does I/O or real computation: a body that builds a tuple is 1.5% of firing and costs
  more than that to hand to a task, so break-even is about 5 µs. Sixty-four bodies
  sleeping 5 ms go from 385 ms to 7 ms.

  It preserves the resulting session, asserted by a property over a ruleset spanning every
  node kind. It does **not** preserve firing order, because taking a group freezes it
  while firing one at a time re-sorts the agenda after every activation. A body may also
  run for a match another activation in the same group then invalidates: that activation
  does not fire and nothing it computed is inserted, but a side effect it performed is not
  undone. `docs/dsl.md` states the at-least-once contract this implies, and
  `docs/design/engine.md` §11 has the measurements.

### Observability

* `Rete.Listener` — one callback, every event emitted in one place, costing nothing when
  nobody is listening. `Rete.Listener.Collect` and `Rete.Listener.Trace` ship.
* `Rete.Inspect` — `explain/2`, `fired/2`, `why_not/2` and `collection/3`, all derived
  from working memory, so they need no setup and cannot drift. A rule is named the same
  way a query is, by `{module, name}`.

### Naming

* A production is identified by **`{module, name}`**, not by name alone, so two rulesets
  that each define a `:summary` compose into one session. A repeat within one module is
  rejected where it is written, naming both declarations.
* Queries are run by calling them; `Rete.Session.query/3` takes `{module, name}` for the
  runtime-chosen case. A bare name raises, naming the module that defines it.
* Listener events name the rule too. The three activation events and the `:derived`
  origin carry `%{node: node_id, rule: {module, name}}` in place of a bare node id, which
  a listener had no way to resolve. `{:propagated, ...}` still carries the id alone — a
  join node has no name to give.

### The public API

Only `Rete`, `Rete.Ruleset`, `Rete.Session`, `Rete.Inspect` and `Rete.Listener` (with
`Collect` and `Trace`) are covered by semantic versioning. Everything else is documented
but internal and may change in a patch release. See "What is public" in the README.

### Performance

Three quadratics in the size of one join key's bucket, all measured, all linear or flat.
Inserting 4,000 facts under one key went from 250 ms to under 10 ms, and retracting 200 of
them from a bucket of 8,000 from 108 ms to under 1 ms. `mix bench` is what says so, and
keeps saying so.

* `Rete.Agenda` is bucketed by sort key rather than one sorted list. Every activation of
  a production shares a key, so inserting walked past every match already queued for that
  rule; there are at most as many buckets as there are production nodes.
* `Rete.Memory.Bucket` replaces the list behind each join key with an ordered multiset:
  adding and retracting are O(1), reading is unchanged.
* `Rete.Engine.insert/3` and `retract/3` collect their propagation ops without appending
  to the accumulator once per fact.

### Ordering

* Two matches of one rule fire in **arrival order**, at any scale. A batch arriving at a
  node is split into join groups in the order each key first appeared rather than in map
  order; Elixir iterates a map of up to 32 keys in term order and a larger one in an
  internal hash order, so the previous behavior changed a rule's firing sequence the
  moment a node saw its 33rd join key.
* The runaway error says how much it left out. Both of its lists are cut to five, and a
  cut that says nothing reads as the whole story: it reports
  `Still pending (5 of 412 activations)` when there is more, and stays quiet when there
  is not.

### Development

Neither of these ships in the package.

* **CI** (`.github/workflows/ci.yml`) runs the project's six verification commands on the
  declared floor, Elixir 1.18, and on the current release. The floor was a promise
  `mix.exs` made and nothing checked.
* **`mix bench`** (`bench/run.exs`) — nine scaling scenarios reporting the empirical
  exponent rather than a wall-clock number, so a reintroduced quadratic shows up as `~n^2`
  instead of as a figure with no baseline. Eight are linear. Filling one collection
  measures `~n^1.94` and is left in, because a suite that reported only good news would be
  worth less. A tenth scenario compares `:concurrency` settings on a blocking body, which
  is a ratio rather than a shape. Not run in CI — timing thresholds on shared runners fail
  for reasons that mean nothing.
