# Changelog

All notable changes to `rete` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

* **The loop guard is opt-in.** `:max_cycles` now defaults to `:infinity`, so
  `fire_rules/2` runs to quiescence and an oscillating ruleset spins rather than raising.
  The old default of 10,000 was reached by 4,000 facts through a three-rule chain — no
  loop in sight — and a count cannot separate a runaway from a large settling pass, so
  any default eventually fails correct code. Pass an integer to bound a call.
  `docs/design/observability.md` §3 has the numbers for picking one. An unrecognised value
  raises rather than quietly meaning no cap, which is what `max_cycles: nil` used to do
  by accident of Erlang term order.
* `mix.exs` no longer declares `extra_applications: [:logger]`. Nothing in the engine
  logs; tracing goes through `Rete.Listener.Trace`.
* **`:max_cycles` counts cycles, not activations.** A cycle is one pass of the fire loop:
  one activation at the default concurrency, one whole activation group above it. The two
  coincide at `concurrency: 1`, so nothing changes unless you raise it. The runaway error
  now says "fired n cycles".

### Added

* **`:concurrency` and `:timeout` on `fire_rules/2`.** `concurrency: 1` by default, which
  is the sequential path unchanged. Above `1`, the rule bodies of one activation group run
  on tasks and their conclusions are applied in group order. Worth raising only when a
  body does I/O or real computation — a body that builds a tuple is 1.5% of firing and
  costs more than that to hand to a task, so break-even is about 5 µs. Sixty-four bodies
  sleeping 5 ms go from 385 ms to 7 ms.

  It preserves the resulting session, asserted by a property over the every-node-kind
  ruleset. It does **not** preserve firing order, because popping a group freezes it while
  firing one at a time re-sorts the agenda after every activation. A body may also run for
  a match another activation in the same group then invalidates — conclusions are still
  retracted, side effects are not. `docs/dsl.md` states the at-least-once contract, and
  `docs/design/engine.md` §11 has the measurements.
* **CI** (`.github/workflows/ci.yml`) running the project's six verification commands on
  the declared floor, Elixir 1.18, and on the current release. The floor was a promise
  `mix.exs` made and nothing checked.
* **`mix bench`** (`bench/run.exs`) — nine scaling scenarios reporting the empirical
  exponent rather than a wall-clock number, so that a reintroduced quadratic shows up as
  `~n^2` instead of as a figure with no baseline. Eight are linear; filling one collection
  measures `~n^1.94` and is left in, because a suite that reported only good news would
  be worth less. Not run in CI — timing thresholds on shared runners fail for reasons
  that mean nothing.

## 0.1.0

First release. A complete forward-chaining Rete engine: the DSL front end, the network
compiler, the propagation loop, truth maintenance and the observability tools.

`0.1.0` rather than `1.0.0` deliberately. Everything documented works and is covered by
660 tests, but one part of the surface is known to be unsettled and is likely to change
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
* A loop guard, `:max_cycles`, raising with the rules that fired most.

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

Three quadratics in the size of one join key's bucket, all measured, all now linear or
flat. Inserting 4,000 facts under one key went from 250 ms to under 10 ms, and retracting
200 of them from a bucket of 8,000 from 108 ms to under 1 ms.

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
  internal hash order, so the previous behaviour changed a rule's firing sequence the
  moment a node saw its 33rd join key.
* The runaway error says how much it left out. Both of its lists are cut to five, and a
  cut that says nothing reads as the whole story: it now reports
  `Still pending (5 of 412 activations)` when there is more, and stays quiet when there
  is not.
