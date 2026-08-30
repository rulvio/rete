# Changelog

All notable changes to `rete` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
  still rejected.
* Queries are run by calling them; `Rete.Session.query/3` takes `{module, name}` for the
  runtime-chosen case. A bare name raises, naming the module that defines it.
