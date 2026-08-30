# Shared context

Every prompt in this directory starts by asking you to read this file. It is the
briefing common to all of them.

---

## The project

`rete` at `/Users/jgomez/repos/github.com/rulvio/rete` is a **forward-chaining Rete rules
engine in Elixir**.

A Clojure Rete engine, **Clara**, lives at
`/Users/jgomez/repos/github.com/gateless/clara-rules`. It is a **semantic reference only** —
it tells you *what behaviour must hold*. It is explicitly **not** a codebase to translate.
The user was emphatic about this:

> "I don't want this to turn into a translation of clara-rules and its clojure idioms to
> Elixir, it should be a genuine implementation of a Rete engine with Powerful DSL in Elixir."

Write idiomatic Elixir: structs, protocols, pattern matching, immutable maps and `MapSet`,
`Enum`/`Stream`. Do **not** reproduce Clojure artifacts — the transient-vs-persistent memory
duality, `ITransport`, four separate activation protocols, `ham-fisted` mutable collections,
or mutable identity-comparison flags. Every one of those is a JVM performance artifact, and
this engine deliberately does the BEAM-native thing instead.

## The DSL, which is the point of the project

A rule reads as a function: **its arguments are the left hand side**, and **its body is the
right hand side**. Pattern matching gives destructuring, variable binding and join-variable
identification for free, and the value the body returns is the facts to insert.

```elixir
defmodule MyRuleset do
  use Rete.Ruleset

  derive :premium, :customer

  defrule loyalty(
            %{salience: 100},
            {:customer, cid, name},
            orders = [{:order, cid, _amt}]
          ) do
    {:loyalty, cid, name, length(orders)}
  end

  defrule big_order({:threshold, t}, {:order, cid, amt} when amt > t) do
    {:flagged, cid, amt}
  end

  defrule dormant({:customer, cid, _}, {:not, [{:order, cid, _}]}) do
    {:dormant, cid}
  end

  defquery flagged_for({:flagged, cid, amt}) do
    {cid, amt}
  end
end
```

LHS element forms:

```
{:type, a, b, ...}              fact pattern, any arity, including {:tick}
%Mod{f: v}                      struct fact pattern, the type is the module
%{__type__: :user, id: id}      tagged map fact pattern
user = {:user, id}              bind the whole fact
{:order, total} when total > 10 per condition guard
[{:order, id}]                  collect all matching facts (anonymous)
orders = [{:order, id}]         collect all matching facts, bound
{:not, [{:order, id}]}          gate: :and :or :not :nand :nor :xor :xnor
```

A `%{...}` literal in first position is the rule options (`salience`, `params`), not a
condition. A `when` after the whole argument list is a guard over all bindings.

## Locked design decisions — do not relitigate

These were decided by the user explicitly. If you think one is wrong, **say so and stop**;
do not quietly change it.

- **Collection bindings are collect-all only.** `bars = [{:bar, id}]` gathers matching facts
  into a list. There is **no** accumulator library — no `min`/`max`/`sum`/`count`. Users do
  that in the RHS with `Enum`.
- **Empty-collection rule.** A collection introducing no *new* variables propagates `[]` and
  the rule fires with zero matches. One that *does* introduce a new variable groups by it,
  and a group only exists where a fact created it. Precomputed as `:propagates_empty?` on the
  accumulate nodes.
- **Logical inserts only.** The RHS returns facts to insert, and they are truth-maintained.
  There is **no** unconditional insert and **no** RHS retract. Session-level
  `Rete.Session.retract/2` exists, and truth maintenance cascades from it.
- **Facts are a multiset.** Inserting the same fact twice needs two retractions to remove it.
- **Taxonomy is applied by the alpha index**, never inside an alpha expression. An alpha
  expression matches a fact of *any* type on purpose; which alphas a fact reaches is decided
  by `Rete.Taxonomy` from the fact's type and its `derive`d ancestors.
- **Out of scope entirely**: caches (session, compiler, expression), async/parallel rule
  firing, durability/serialization, performance tuning. Correctness and DSL synergy first.

## Where things are

```
lib/rete.ex                     aggregates rule/expr/taxo data across ruleset modules
lib/rete/ruleset.ex             the defrule/defquery/derive/underive macros
lib/rete/ir.ex                  Rete.IR — condition and production structs

lib/rete/dsl/vars.ex            scope-aware variable analysis (pattern binds vs expr reads)
lib/rete/dsl/parser.ex          AST -> IR
lib/rete/dsl/normalize.ex       gate desugaring, de Morgan, per-condition DNF
lib/rete/dsl/bindings.ex        join/new classification, guard splitting
lib/rete/dsl/codegen.ex         emits alpha / join_filter / test / rhs functions

lib/rete/taxonomy.ex            fact type -> alpha id index, backed by the `taxo` hex package
lib/rete/compiler/sort.ex       stable topological condition sort
lib/rete/compiler/negation.ex   compound negation extraction into helper productions
lib/rete/compiler/beta_graph.ex beta nodes, edges, and node sharing
lib/rete/network/node.ex        node structs and the sharing key
lib/rete/network.ex             the compiled rulebase
lib/rete/compiler.ex            build entry point and validation

lib/rete/token.ex               Token, Element, Activation
lib/rete/memory.ex              the five working memories
lib/rete/agenda.ex              salience-ordered activations
lib/rete/engine/state.ex        the state threaded through propagation
lib/rete/engine/nodes.ex        what each node kind does  <-- the heart of the engine
lib/rete/engine.ex              propagation loop, fire cycle, truth maintenance
lib/rete/session.ex             the public API

docs/design/w1-ir.md            the IR and DSL front-end contract
docs/design/w2-network.md       the compiled network contract, and what the engine must honour
```

**Read `docs/design/w1-ir.md` and `docs/design/w2-network.md` before touching anything.**
They document the field-by-field contracts, the sharing rules, the guard-splitting rules and
a "known gaps" section in each. Do not re-derive any of it from the code.

## Architecture, and the one decision everything follows from

Clara propagates by **mutating a transient memory** while calling down the node tree, then
converts back to a persistent memory at the end of `fire-rules`. That duality is why it needs
`ITransport`, four activation protocols, and 17 listener methods sprinkled through every node.

This engine instead runs a **flat propagation loop over an explicit work queue**. A node is a
function of state that returns the new state plus the work it produced; the loop does the
walking:

```elixir
# lib/rete/engine/nodes.ex
handle(state, {op_kind, node_id, items}) :: {state, [op]}
```

Consequences, all of which you should preserve:

- No transport abstraction — it was indirection for a distributed transport that never shipped.
- One immutable `Rete.Memory` threaded through a fold, so a session is a **value**.
- Propagation is flat iteration, so a deep cascade costs no stack.
- **Events can be emitted in exactly one place — the loop** — rather than scattered across
  every node. This is what makes the listener work in W5 cheap.

## How to drive it

```elixir
session = Rete.Session.new([SomeRuleset])
session = Rete.Session.insert(session, [{:a, 1}])
session = Rete.Session.fire_rules(session)

Rete.Session.facts(session)              # inserted and concluded, markers excluded
SomeRuleset.some_query(session)          # a query is a function in its module
SomeRuleset.by_cid(session, %{cid: 1})
Rete.Session.query(session, {SomeRuleset, :by_cid}, %{cid: 1})   # when chosen at runtime
Rete.Session.pending(session)            # activations waiting to fire
Rete.Session.network(session)

session.state.memory   # .elements .tokens .accum .insertions .facts
session.state.agenda
```

`mix run` with a scratch script in `/tmp` is the easiest way to experiment.

## Working agreement

- `mix test` and `mix compile --force --warnings-as-errors` must pass before you report done.
- `mix format` everything you touch. `.formatter.exs` has `locals_without_parens` for the DSL
  macros, so `defrule name(...) do ... end` keeps its shape — do not remove that.
- Add tests for everything you build, and a regression test for every bug you fix.
- **Keep the suite fast.** It is ~5 s today. Never add a test that compiles a pathological
  rule; assert that a size guard raises rather than waiting for a blowup.
- Do **not** `git commit`. Leave changes in the working tree.
- If you conclude a reported defect is not a bug, say so with reasoning rather than skipping
  it silently.

## The lesson that matters most on this project

**Facts alone are a weak lens, and a passing test suite is not evidence.**

When a node propagates a token it had already propagated, the duplicate fact collapses into a
count bump in the multiset. `Rete.Session.facts/1` looks perfect. The corruption only surfaces
much later, as a fact that survives the retraction that should have removed it.

Three separate times on this project, a suite that passed cleanly was hiding real bugs:

1. W3's engine tests passed 40/40 on the first run. Mutation testing — deliberately breaking
   the engine seven ways — showed **only one of seven was caught**.
2. Strengthening the invariant to "after retracting everything, every *memory* is empty, not
   just the facts" **immediately failed on unmutated code** and exposed an unbounded leak.
3. An adversarial review then found six more tests weaker than their names promised, including
   a `strip/1` helper written to make that very invariant pass, which masked the residue that
   turned out to be a second real leak one level up.

So: **assert on `session.state.memory`, not just on facts.** The invariants that actually
catch engine bugs are

- retract everything, then assert every memory equals a **fresh session's** memory
  (`Rete.Session.new([Mod]).state.memory`) — that pins both "drained" and "exactly one root
  token", which an "everything is empty" check structurally cannot see;
- support counts are 1 where only one rule concluded a fact;
- round trip: insert X, fire, retract X, fire, compare against the state before;
- order independence: the same facts in any order give the same derived state.

And when a test passes on the first try, consider breaking the code on purpose to check the
test can fail at all.

## Reference points in Clara

Useful when you need the *semantics*. Read them; do not port them.

```
src/main/clojure/clara/rules/engine.clj      2370 lines — node behaviour, TMS, fire cycle
src/main/clojure/clara/rules/compiler.clj    2214 lines — DNF, condition sort, beta graph
src/main/clojure/clara/rules/memory.clj       904 lines — working memory
src/main/clojure/clara/rules/listener.clj     183 lines — the event protocol
src/main/clojure/clara/tools/inspect.clj      456 lines — session inspection, explanations
src/main/clojure/clara/tools/tracing.clj      175 lines — the tracing listener
src/main/clojure/clara/tools/loop_detector.clj 105 lines — cycle detection
src/main/clojure/clara/tools/fact_graph.clj    96 lines — fact provenance as a graph
src/test/clojure/clara/                      ~8000 lines of behavioural tests
```

Two Clara issues came up repeatedly and are worth knowing by number:

- **Issue 433** — a node may be shared only when it is equal **and has the same parent set**.
  Two rules whose second conditions are identical but whose first conditions differ must not
  share, or facts leak between rules.
- **Issue 304** — an extracted compound negation's marker fact must carry the ancestor
  bindings the conjunction joins on, or the negation becomes global instead of per-binding-group.

Both are implemented and tested here. Do not regress them.
