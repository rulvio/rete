# Rete

[![CI](https://github.com/rulvio/rete/actions/workflows/ci.yml/badge.svg)](https://github.com/rulvio/rete/actions/workflows/ci.yml)

A forward-chaining [Rete](https://en.wikipedia.org/wiki/Rete_algorithm) rules engine for Elixir,
in which a rule reads as a function: its **arguments are the conditions** and its **body is what
follows**. It is for the part of an application where the logic is a pile of interacting
conditions — pricing, eligibility, alerting, policy, validation, diagnosis — the code that turns
into a nest of `cond` clauses nobody wants to touch, and where the interesting question is not
"what happens next" but "what is true now".

```elixir
defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
  {:dormant, name}
end
```

Pattern matching in the argument list gives destructuring, variable binding and join-variable
identification for free: `cid` appearing in two conditions *is* the join. Everything a rule
concludes is truth-maintained — retract the order and the customer becomes dormant again, with no
bookkeeping on your side.

## Installation

```elixir
def deps do
  [
    {:rete, "~> 0.1.0"}
  ]
end
```

Documentation: <https://hexdocs.pm/rete>. The rule-writing reference is
[docs/dsl.md](docs/dsl.md).

## How a Rete engine thinks

Most Elixir code is a pipeline: you call a function, it returns a value, and control moves on. A
rules engine inverts that. You put **facts** into a session; the engine works out which **rules**
match them and what those rules conclude; and it keeps the conclusions consistent as the facts
change. You never call a rule.

Four ideas carry the whole model.

**Facts are plain data.** A tagged tuple, a struct, or a map with a `__type__` key. There is no
fact API — `{:order, 1, 250}` is a fact.

**A rule is a pattern over several facts at once.** Its conditions are matched independently and
then joined on the variables they share. Where a `cond` has to name the order in which things are
checked, a rule just states the shape of the world it cares about, and the engine finds every
combination of facts with that shape. One combination is one *match*, and one match fires the
rule once.

**Nothing runs until you say so.** `insert/2` propagates facts through the network and queues the
matches it finds; `fire_rules/2` runs them. That lets a batch of facts be reasoned about together
instead of each one triggering a cascade of its own.

**Conclusions are held up by their support, not by having happened.** When a rule fires, the
facts it returns are inserted *logically*: the engine remembers which match produced them. Take
away any fact behind that match and the conclusion is withdrawn — and so is anything concluded
from *it*, until the session settles. This is what a rules engine gives you that a pile of
functions does not, and it is why the right hand side can only insert: keeping a conclusion true
as the world changes is the engine's job, not yours.

The name comes from the algorithm underneath. Rete compiles the rules into a network that shares
work between them: a condition written in four rules is matched once per fact, and partial matches
are remembered, so inserting one fact costs work proportional to what that fact actually affects
rather than to the size of the rulebase.

## A worked example

```elixir
defmodule Retail do
  use Rete.Ruleset

  # An online order is a kind of order, so rules about orders see both.
  derive :online_order, :order

  # An order over the current threshold is large.
  defrule large_order({:threshold, limit}, {:order, cid, amt} when amt > limit) do
    {:large_order, cid, amt}
  end

  # Total up everything a customer ordered.
  defrule spend({:customer, cid, name}, orders = [{:order, cid, _amt}]) do
    {:spend, name, Enum.sum(for {_, _, amt} <- orders, do: amt)}
  end

  # A customer with no orders at all.
  defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
    {:dormant, name}
  end

  defquery large_orders({:large_order, cid, amt}) do
    {cid, amt}
  end
end
```

Four LHS forms are in there: a plain pattern, a per-condition guard (`when amt > limit`), a
collection (`orders = [...]`, which gathers every matching fact into a list) and a negation
(`{:not, [...]}`). `cid` is the join variable throughout.

### Insert

```elixir
session =
  Rete.Session.new([Retail])
  |> Rete.Session.insert([
    {:threshold, 100},
    {:customer, 1, "Ada"},
    {:customer, 2, "Bo"},
    {:order, 1, 250},
    {:order, 1, 40},
    {:online_order, 2, 30}
  ])

Rete.Session.facts(session)
#=> the six facts above, and nothing else

length(Rete.Session.pending(session))
#=> 3
```

Nothing has been concluded, because nothing has fired. What *has* happened is the matching: three
activations are queued — `large_order` for Ada's 250, and `spend` for each customer. Each carries
the bindings it matched with:

```elixir
%Rete.Activation{
  node_id: 3,
  token: %Rete.Token{
    matches: [{{:threshold, 100}, 1}, {{:order, 1, 250}, 2}],
    bindings: %{limit: 100, cid: 1, amt: 250}
  },
  salience: 0,
  ...
}
```

### Fire

```elixir
session = Rete.Session.fire_rules(session)

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:large_order, 1, 250},
#     {:online_order, 2, 30},
#     {:order, 1, 40},
#     {:order, 1, 250},
#     {:spend, "Ada", 290},
#     {:spend, "Bo", 30},
#     {:threshold, 100}
#   ]
```

Three things to notice. `{:order, 1, 40}` did not produce a `:large_order`, because the guard runs
against the threshold *fact*, so changing the threshold changes the answer. `{:spend, "Ada", 290}`
is one activation over a list of two orders, not two activations. And Bo's spend counts an
`{:online_order, ...}`, because `derive :online_order, :order` puts it under `:order` in the
taxonomy — the rule never mentions online orders.

Nobody is dormant: both customers have orders.

### Query

A query has the same left hand side as a rule, but it never fires: it holds the matches that
reached it, and **it is a function in its own module** — so you read it back by calling it.

```elixir
Retail.large_orders(session)
#=> [{1, 250}]

Retail.large_orders(session, cid: 1)
#=> [{1, 250}]
```

A query returns **what its body computes**, one result per match — so it answers in whatever
shape suits the caller rather than handing back raw bindings. There is nothing to declare:
any variable the left hand side binds can be constrained at call time, and naming one it does
not bind raises rather than quietly answering `[]`.

Because a query is identified by `{module, name}` and never by a bare name, two rulesets that
each define a `:summary` compose into one session without collision. When the query is chosen
at runtime, name the pair: `Rete.Session.query(session, {Retail, :large_orders}, cid: 1)`.

### Retract

```elixir
session =
  session
  |> Rete.Session.retract({:order, 1, 250})
  |> Rete.Session.fire_rules()

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:online_order, 2, 30},
#     {:order, 1, 40},
#     {:spend, "Ada", 40},
#     {:spend, "Bo", 30},
#     {:threshold, 100}
#   ]
```

`{:large_order, 1, 250}` is gone — nothing retracted it, its support went away. `{:spend, "Ada",
290}` is gone too, replaced by `{:spend, "Ada", 40}`: the collection is part of the match, so a
different list is a different match.

Retract the rest and the dormancy rules take over:

```elixir
session =
  session
  |> Rete.Session.retract([{:order, 1, 40}, {:online_order, 2, 30}])
  |> Rete.Session.fire_rules()

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:dormant, "Ada"},
#     {:dormant, "Bo"},
#     {:spend, "Ada", 0},
#     {:spend, "Bo", 0},
#     {:threshold, 100}
#   ]
```

The `:spend` rule still fires, with an empty list, because its collection introduces no variable of
its own — see the empty-collection rule in [docs/dsl.md](docs/dsl.md). `:dormant` fires now that
the negation holds.

### Ask why

```elixir
Rete.Inspect.explain(session, {:dormant, "Ada"})
#=> [
#     %{
#       fact: {:dormant, "Ada"},
#       rule: :dormant,
#       origin: :derived,
#       bindings: %{cid: 1, name: "Ada"},
#       supports: [%{fact: {:customer, 1, "Ada"}, rule: nil}]
#     }
#   ]
```

One entry per independent support: a fact concluded twice needs both to go before it does.
`Rete.Inspect` also has `fired/2` (what has concluded something), `why_not/2` (how far a rule got,
condition by condition) and `collection/3`. For history rather than a snapshot, attach
`Rete.Listener.Collect` or `Rete.Listener.Trace`.

### Sessions are values

Every operation returns a new session and changes nothing:

```elixir
quiet = Rete.Session.new([Retail]) |> Rete.Session.insert({:customer, 1, "Ada"})
busy = quiet |> Rete.Session.insert({:order, 1, 250}) |> Rete.Session.fire_rules()
# `quiet` is untouched, and can be reused as a checkpoint
```

The compiled network is shared rather than copied, so a session is cheap to hold, cheap to fork
and safe to pass between processes. Compiling is the expensive part: do it once with
`Rete.Compiler.build/2` and start sessions from it with `Rete.Session.from_network/1`.

## What is public

Seven modules, and they are the ones the examples above use:

| module | for |
|---|---|
| `Rete` | aggregating rule, expression and taxonomy data across ruleset modules |
| `Rete.Ruleset` | `defrule`, `defquery`, `derive`, `underive` |
| `Rete.Session` | building a session, inserting, retracting, firing, querying |
| `Rete.Inspect` | `explain/2`, `fired/2`, `why_not/2`, `collection/3` |
| `Rete.Listener` (+ `.Collect`, `.Trace`) | watching what a session does |

**Everything else is internal** — the DSL front end, the IR, the compiler, the network,
the engine, working memory, the agenda, and the value structs. It is documented, because
durability, checkpointing and tooling will eventually need to reach in, and `docs/design/`
carries the reasoning behind it. But it is not covered by semantic versioning and it may
change in a patch release. The generated docs group it under `Internals:` headings for
exactly this reason.

Two internals do reach you through the public API: `Rete.Session.pending/1` returns
`Rete.Activation` structs, and every listener event carries a `Rete.Token`. **Read their
fields freely; do not depend on their functions**, and expect the field sets to change.

## Limitations

Correctness and DSL clarity came first; several things were left out on purpose, and the
design docs under `docs/design/` record why.

* **Collections are collect-all.** `orders = [{:order, cid, amt}]` gathers matching facts into a
  list. There is no accumulator library — no `min`, `max`, `sum`, `count`, no custom accumulators.
  Do it in the right hand side with `Enum`.
* **Logical inserts only.** A rule's body returns facts to insert and they are truth-maintained.
  There is no unconditional insert and no retract from a rule. Session-level
  `Rete.Session.retract/2` exists and truth maintenance cascades from it.
* **Firing is synchronous.** `fire_rules/2` runs to quiescence in the calling process. No parallel
  or async rule evaluation.
* **No durability.** A session is an in-memory value. It is not serialized, checkpointed or
  distributed; nothing here is a database.
* **Performance is untuned.** The algorithm is the right one — alpha and beta node sharing, hash
  joins, incremental retraction — but no profiling pass has been done and no benchmark suite
  exists. Expect it to be fast enough long before it is fast.
* **Per-group firing over a collection is awkward.** Grouping falls out of a collection
  introducing a new variable, and reaching that in practice needs two collections. Collect
  everything and `Enum.group_by/2` instead.
* **No rule subsumption or suffix sharing.** Two rules sharing a condition prefix share nodes; two
  sharing only a suffix do not.

## Development

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

CI runs exactly those, on the declared floor (Elixir 1.18) and on the current release.

```bash
mix bench
```

Scaling benchmarks. They report the **empirical exponent** — the k in O(n^k), read off
the growth between one size and the next — rather than a wall-clock figure nobody has a
baseline for. The failure mode this engine actually has is not a slow function but an
operation that turns out to be quadratic in something a session accumulates, and that is
invisible to a single-size measurement. Around `~n^1` is fine; `~n^2` is a bug, unless it
is one of the known gaps in `docs/design/`. Not in CI: wall-clock thresholds on shared
runners fail for reasons that mean nothing.

## Acknowledgements

**[Clara](https://github.com/cerner/clara-rules)** is the semantic reference for this engine.
Where a question about behaviour had no obvious answer — what a negated conjunction means when its
conjuncts share a variable, when two nodes may be shared, how truth maintenance interacts with a
fact concluded twice — Clara's answer was taken as the specification, and two of its issues (433
on node sharing, 304 on scoped negation markers) are implemented and regression-tested here.

None of Clara's code was ported. Clara is Clojure on the JVM and its architecture reflects that:
transient-versus-persistent memory, a transport abstraction, four activation protocols, listener
calls scattered through every node. This engine does the BEAM-native thing instead — a flat
propagation loop over an explicit work queue, one immutable memory threaded through a fold, and
events emitted in exactly one place.

**[taxo](https://github.com/rulvio/taxo)** provides the type hierarchies behind `derive` and
`underive`.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
