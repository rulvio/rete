# Rete

[![CI](https://github.com/rulvio/rete/actions/workflows/ci.yml/badge.svg)](https://github.com/rulvio/rete/actions/workflows/ci.yml)

This project is a forward-chaining rules engine for Elixir, based on the
[Rete algorithm](https://en.wikipedia.org/wiki/Rete_algorithm). A rule reads as a function:
its **arguments are the conditions**, and its **body is what follows**.

Use it where the logic is a pile of interacting conditions: pricing, eligibility, alerting,
policy, validation, or diagnosis. This is the code that becomes a nest of `cond` clauses
nobody wants to touch. The question that matters here is not "what happens next" but "what
is true now".

```elixir
defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
  {:dormant, name}
end
```

Pattern matching in the argument list gives you destructuring, variable binding, and
join-variable identification for free. `cid` appearing in two conditions *is* the join.

Everything a rule concludes is truth-maintained. Retract the order, and the customer
becomes dormant again. You do no bookkeeping yourself.

## Installation

```elixir
def deps do
  [
    {:rete, "~> 0.2.0"}
  ]
end
```

Documentation: <https://hexdocs.pm/rete>. The rule-writing reference is
[docs/dsl.md](docs/dsl.md).

## How a Rete engine thinks

Most Elixir code is a pipeline: you call a function, it returns a value, and control moves
on. A rules engine inverts that model.

You put **facts** into a session. The engine works out which **rules** match them and what
those rules conclude. It keeps the conclusions consistent as the facts change. You never
call a rule yourself.

Four ideas carry the whole model.

**Facts are plain data.** A fact is a tagged tuple, a struct, or a map with a `__type__`
key. There is no fact API. `{:order, 1, 250}` is a fact.

**A rule is a pattern over several facts at once.** The engine matches its conditions
independently, then joins them on the variables they share.

A `cond` clause must name the order it checks things in. A rule instead states the shape of
the world it cares about. The engine finds every combination of facts with that shape. One
combination is one *match*. One match fires the rule once.

**Nothing runs until you say so.** `insert/2` propagates facts through the network and
queues the matches it finds. `fire_rules/2` runs the queued matches.

This lets you reason about a batch of facts together. Otherwise each fact would trigger a
cascade of its own.

**Conclusions are held up by their support, not by having happened.** When a rule fires,
the engine inserts the facts it returns *logically*. It remembers which match produced each
fact.

If you take away any fact behind that match, the conclusion is withdrawn. Anything
concluded from that conclusion is withdrawn too, until the session settles. A pile of
functions cannot give you this. It is also why a rule's right hand side can only insert
facts: keeping a conclusion true as the world changes is the engine's job, not yours.

The name comes from the algorithm underneath. Rete compiles the rules into a network that
shares work between them.

A condition written in four rules is matched once per fact. The network remembers partial
matches. Because of this, inserting one fact costs work proportional to what that fact
actually affects, not to the size of the rulebase.

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

  # Add up everything a customer ordered.
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

This example uses four left hand side forms:

* a plain pattern
* a per-condition guard (`when amt > limit`)
* a collection (`orders = [...]`), which gathers every matching fact into a list
* a negation (`{:not, [...]}`)

`cid` is the join variable throughout.

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

Nothing has been concluded, because nothing has fired. What *has* happened is the matching.
Three activations are queued: `large_order` for Ada's 250, and `spend` for each customer.
Each activation carries the bindings it matched:

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

`salience` is firing priority. A rule declared `defrule urgent(%{salience: 10}, ...)` fires
before one at the default value of `0`. Every activation at one salience level fires before
any activation at a lower one. See
[docs/dsl.md#options-salience](docs/dsl.md#options-salience) for more.

### Fire

`fire_rules/2` also takes `:max_cycles`, `:concurrency`, and `:timeout`. See its own doc and
[docs/design/engine.md](docs/design/engine.md) §11 for more.

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

Three things to notice here:

1. `{:order, 1, 40}` did not produce a `:large_order`. The guard runs against the threshold
   *fact*, so changing the threshold changes the answer.
2. `{:spend, "Ada", 290}` is one activation over a list of two orders, not two activations.
3. Bo's spend counts an `{:online_order, ...}` fact too. `derive :online_order, :order` puts
   it under `:order` in the taxonomy, so the rule matches it even though the rule never
   mentions online orders.

Nobody is dormant, because both customers have orders.

### Query

A query has the same left hand side as a rule, but it never fires. It holds the matches
that reached it. **It is a function in its own module**, so you read it back by calling it.

```elixir
Retail.large_orders(session)
#=> [{1, 250}]

Retail.large_orders(session, cid: 1)
#=> [{1, 250}]
```

A query returns **what its body computes**, one result per match. It answers in whatever
shape suits the caller, instead of handing back raw bindings.

There is nothing to declare. You can constrain any variable the left hand side binds, at
call time. Naming a variable the left hand side does not bind raises an error, instead of
quietly answering `[]`.

A query is identified by `{module, name}`, never by a bare name. Because of this, two
rulesets that each define a `:summary` compose into one session without collision.

When you choose the query at runtime, name the pair:
`Rete.Session.query(session, {Retail, :large_orders}, cid: 1)`.

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

`{:large_order, 1, 250}` is gone. Nothing retracted it directly. Its support went away.

`{:spend, "Ada", 290}` is gone too, replaced by `{:spend, "Ada", 40}`. The collection is
part of the match, so a different list is a different match.

Retract the rest of the facts. The dormancy rules take over:

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

The `:spend` rule still fires, with an empty list. Its collection introduces no variable of
its own. See the empty-collection rule in [docs/dsl.md](docs/dsl.md) for why.

`:dormant` fires now that the negation holds.

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

Each entry is one independent support. A fact concluded twice needs both supports to go
before the fact itself goes.

`Rete.Inspect` also has:

* `fired/2` — what has concluded something
* `why_not/2` — how far a rule got, condition by condition
* `collection/3`

For history instead of a snapshot, attach `Rete.Listener.Collect` or `Rete.Listener.Trace`.

### Sessions are values

Every operation returns a new session and changes nothing:

```elixir
quiet = Rete.Session.new([Retail]) |> Rete.Session.insert({:customer, 1, "Ada"})
busy = quiet |> Rete.Session.insert({:order, 1, 250}) |> Rete.Session.fire_rules()
# `quiet` is untouched. Reuse it as a checkpoint.
```

The compiled network is shared, not copied. Because of this, a session is cheap to hold,
cheap to fork, and safe to pass between processes.

Compiling is the expensive part. Do it once, with `Rete.Compiler.build/2`. Start sessions
from the result with `Rete.Session.from_network/1`.

## What is public

Seven modules are public. They are the ones the examples above use:

| module | for |
|---|---|
| `Rete` | aggregating rule, expression and taxonomy data across ruleset modules |
| `Rete.Ruleset` | `defrule`, `defquery`, `derive`, `underive` |
| `Rete.Session` | building a session, inserting, retracting, firing, querying |
| `Rete.Inspect` | `explain/2`, `fired/2`, `why_not/2`, `collection/3` |
| `Rete.Listener` (+ `.Collect`, `.Trace`) | watching what a session does |

**Everything else is internal**: the DSL front end, the IR, the compiler, the network, the
engine, working memory, the agenda, and the value structs.

It is documented, because durability, checkpointing, and tooling will eventually need to
reach in. `docs/design/` carries the reasoning behind it. Semantic versioning does not
cover this internal part. It may change in a patch release. The generated docs group it
under `Internals:` headings for this reason.

Two internal structs do reach you through the public API. `Rete.Session.pending/1` returns
`Rete.Activation` structs. Every listener event carries a `Rete.Token`.

**Read their fields freely. Do not depend on their functions.** Expect the field sets to
change.

## Limitations

Correctness and DSL clarity came first. Several things were left out on purpose. The design
docs under `docs/design/` record why.

* **Collections are collect-all.** `orders = [{:order, cid, amt}]` gathers matching facts
  into a list. There is no accumulator library: no `min`, `max`, `sum`, `count`, and no
  custom accumulators either. Do this work in the right hand side with `Enum` instead.
  Gathering is linear, and reducing in the body is the shape to write. Concluding a fact
  that *holds* the collection is not — see `docs/dsl.md`.
* **Logical inserts only.** A rule's body returns facts to insert. The engine truth-maintains
  them. There is no unconditional insert and no retract from a rule. Session-level
  `Rete.Session.retract/2` exists. Truth maintenance cascades from it.
* **Firing is a blocking call.** `fire_rules/2` runs to quiescence in the calling process,
  and it returns the settled session. There is no async variant that hands back a `Task`.
  Within one call, the bodies of one salience group *can* run concurrently: pass
  `:concurrency` (and optionally `:timeout`) to run them on tasks, instead of one at a time.
  This is worth it only for a body that does real work — see
  [docs/design/engine.md](docs/design/engine.md) §11 for the ~5 µs break-even point.
* **No checkpoint or migration API, but a session is trivially serializable.** There is no
  `Session.dump/1`, no versioned migration, and no distributed sync built in. A session
  holds no PID, no ETS table, and no other process-local handle. It is plain data all the
  way down, plus function references into the ruleset and listener modules that built it.
  Because of this, `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` round-trip a
  whole session as-is, including its compiled network, with no wrapper needed. The one real
  requirement: the receiving process must have the same compiled ruleset and listener
  modules loaded, since the function references resolve against them.
* **Performance is measured by shape, not tuned for a number.** The algorithm is the right
  one: alpha and beta node sharing, hash joins, incremental retraction. Two profiling
  passes have run, and `mix bench` keeps their results honest by reporting the empirical
  exponent of each scenario rather than a wall-clock figure. Every scenario in the suite is
  linear except one, which is left in deliberately and named in
  [docs/design/engine.md](docs/design/engine.md) §12 along with what it would take to fix.
  What has *not* been done is tuning for absolute throughput, or measuring wide
  disjunctions, many rules over one fact type, or memory rather than time.
* **Per-group firing *within* a collection is awkward.** This differs from `salience`,
  which already groups the *agenda* — every activation at one salience tier fires before
  any activation at a lower one. What is awkward is grouping the *facts inside one rule's
  own collection* — one activation per customer's orders, say. This falls out of a
  collection introducing a new variable. Reaching it in practice needs two collections.
  Collect everything instead, and use `Enum.group_by/2`.
* **No rule subsumption or suffix sharing.** Two rules that share a condition prefix share
  nodes. Two rules that share only a suffix do not.

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

Scaling benchmarks report the **empirical exponent**: the k in O(n^k), read from the growth
between one size and the next. This is more useful than a wall-clock figure, since nobody
has a baseline for that.

This engine's real failure mode is not a slow function. It is an operation that proves
quadratic in something a session accumulates. A single-size measurement cannot show this.

Around `~n^1` is fine. `~n^2` is a bug, unless `docs/design/` already lists it as a known
gap.

Wall-clock thresholds are not in CI. On shared runners, they fail for reasons that mean
nothing.

## Acknowledgements

**[Clara](https://github.com/cerner/clara-rules)** is the semantic reference for this
engine. When a question about behaviour had no obvious answer, Clara's answer became the
specification. Examples of such questions:

* what a negated conjunction means when its conjuncts share a variable
* when the engine may share two nodes
* how truth maintenance interacts with a fact concluded twice

Two of Clara's issues are implemented and regression-tested here: issue 433 on node
sharing, and issue 304 on scoped negation markers.

This engine ports none of Clara's code. Clara is Clojure on the JVM, and its architecture
reflects that: transient-versus-persistent memory, a transport abstraction, four activation
protocols, and listener calls scattered through every node.

This engine does the BEAM-native thing instead: a flat propagation loop over an explicit
work queue, one immutable memory threaded through a fold, and events emitted in exactly one
place.

**[taxo](https://github.com/rulvio/taxo)** provides the type hierarchies behind `derive`
and `underive`.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
