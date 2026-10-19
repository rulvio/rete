# Rete

[![CI](https://github.com/rulvio/rete/actions/workflows/ci.yml/badge.svg)](https://github.com/rulvio/rete/actions/workflows/ci.yml)

This project is a forward-chaining rules engine for Elixir, based on the
[Rete algorithm](https://en.wikipedia.org/wiki/Rete_algorithm). A rule reads as a function:
its **arguments are the conditions**, and its **body is what follows**.

Use it where the logic is many interacting conditions: pricing, eligibility, alerting,
policy, validation, or diagnosis. This is the code that usually becomes a deep stack of
`cond` clauses that nobody wants to change. The question that matters here is not "what
happens next" but "what is true now".

```elixir
defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
  {:dormant, name}
end
```

Pattern matching in the argument list gives you destructuring, variable binding, and
join-variable identification for free. `cid` appearing in two conditions *is* the join.

Everything a rule concludes is truth-maintained. When the order goes away, the customer
becomes dormant again. You do no bookkeeping yourself.

## Installation

```elixir
def deps do
  [
    {:rete, "~> 1.3"}
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
key. There is no fact API. `{:order, 1, 250}` is a fact. A `__type__` wins over the struct
module, and a type may be any term except `nil`.

**A rule is a pattern over several facts at once.** The engine matches its conditions
independently, then joins them on the variables they share.

A `cond` clause must name the order it checks things in. A rule instead states the shape of
the world it cares about. The engine finds every combination of facts with that shape. One
combination is one *match*. One match fires the rule once.

**Nothing happens until you say so.** `insert/2` records facts and queues the work.
`fire_rules/2` is the only call that matches anything. It propagates everything waiting,
runs the rules that match, and returns once the session settles.

This lets you reason about a batch of facts together. Otherwise each fact would trigger a
cascade of its own.

**Conclusions are held up by their support, not by having happened.** When a rule fires,
the engine inserts the facts it returns *logically*. It remembers which match produced each
fact.

If the match goes away, the conclusion is withdrawn. Anything concluded from that
conclusion is withdrawn too, until the session settles. Plain functions cannot give you
this. It is also why a rule's right hand side can only insert facts. To keep a conclusion
true as the world changes is the work of the engine, and not your work.

**Facts you insert stay.** A session has no retract. To take something back, insert a fact
that says so, and write the rule to read it under `{:not, [...]}`. The new fact breaks the
match, and the engine withdraws what the match concluded. The new fact stays too, so give
each fact a unique id when two can be equal. See
[docs/dsl.md#withdrawing-a-conclusion](docs/dsl.md#withdrawing-a-conclusion).

The name comes from the algorithm underneath. Rete compiles the rules into a network that
shares work between them.

A condition written in four rules is matched once per fact, whether those rules sit in one
module or four. The network remembers partial matches. Because of this, inserting one fact
costs work proportional to what that fact actually affects, not to the size of the
rulebase.

## A worked example

```elixir
defmodule Retail do
  use Rete.Ruleset

  # An online order is a kind of placed order, so rules about placed orders see both.
  derive :online_order, :placed

  # A placed order counts until someone cancels it.
  defrule live({:placed, cid, amt}, {:not, [{:cancelled, cid, amt}]}) do
    {:order, cid, amt}
  end

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

  defquery large_orders(cid)({:large_order, cid, amt}) do
    {cid, amt}
  end
end
```

This example uses four left hand side forms:

* a plain pattern
* a per-condition guard (`when amt > limit`)
* a collection (`orders = [...]`), which gathers every matching fact into a list
* a negation (`{:not, [...]}`)

`cid` is the join variable throughout. The other rules read `{:order, ...}`, which only
`live` concludes. So a cancellation reaches all of them through one negation.

### Insert

```elixir
session =
  Rete.Session.new([Retail])
  |> Rete.Session.insert([
    {:threshold, 100},
    {:customer, 1, "Ada"},
    {:customer, 2, "Bo"},
    {:placed, 1, 250},
    {:placed, 1, 40},
    {:online_order, 2, 30}
  ])

Rete.Session.facts(session)
#=> the six facts above, and nothing else

Retail.large_orders(session, 1)
#=> [] — nothing has matched yet
```

The session holds the facts and nothing else. No matching has happened, so the engine has
activated no rule and no query can answer. `insert/2` records what you told it and queues
the work.

`salience` is firing priority. A rule declared `defrule urgent(%{salience: 10}, ...)` fires
before one at the default value of `0`. Every activation at one salience level fires before
any activation at a lower one. See
[docs/dsl.md#options-salience-and-meta](docs/dsl.md#options-salience-and-meta) for more.

### Fire

`fire_rules/2` also takes `:max_cycles`, `:max_duration`, `:concurrency`, and
`:task_timeout`. A rule body that waits on I/O can return a `Task`, and the result of the
task is its facts. `:concurrency` says how many of those tasks run at once. See its own doc and
[docs/design/engine.md](docs/design/engine.md) §11 for more.

```elixir
session = Rete.Session.fire_rules(session)

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:threshold, 100},
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:large_order, 1, 250},
#     {:online_order, 2, 30},
#     {:order, 1, 40},
#     {:order, 1, 250},
#     {:order, 2, 30},
#     {:placed, 1, 40},
#     {:placed, 1, 250},
#     {:spend, "Ada", 290},
#     {:spend, "Bo", 30}
#   ]
```

Four things to notice here:

1. `live` concluded one `:order` for each placed order, because nobody cancelled one.
2. `{:order, 1, 40}` did not produce a `:large_order`. The guard runs against the threshold
   *fact*, so changing the threshold changes the answer.
3. `{:spend, "Ada", 290}` is one activation over a list of two orders, not two activations.
4. Bo has an order too. `derive :online_order, :placed` puts `{:online_order, ...}` under
   `:placed` in the taxonomy. So `live` matches it, even though the rule never mentions
   online orders.

Nobody is dormant, because both customers have orders.

### Query

A query has the same left hand side as a rule, and it fires as a rule does. Its body runs
during the fire, and the session keeps the result as a row. **It is a function in its own
module**, so you read the rows back by calling it.

```elixir
Retail.large_orders(session, 1)
#=> [{1, 250}]
```

A query returns **what its body computed**, one result per match. It answers in whatever
shape suits the caller, instead of handing back raw bindings.

The `(cid)` before the conditions is the **head** of the query, and it is the argument list
of the function. A head is a list of ordinary Elixir patterns, so you choose the shape a
caller writes:

```elixir
defquery by_pair(cid, tid)(...)             #=> by_pair(session, 1, 2)
defquery by_tuple({cid, tid})(...)          #=> by_tuple(session, {1, 2})
defquery by_map(%{cid: cid, tid: tid})(...) #=> by_map(session, %{cid: 1, tid: 2})
defquery big(cid, amt when amt > 1000)(...) #=> big(session, 1, 5_000)
```

What the patterns bind is what the engine keys the matches on, so a read is a map lookup
and not a scan. A call that does not match raises `FunctionClauseError`. A call of the
wrong arity warns at compile time, and raises `UndefinedFunctionError` when it runs. Each
is reported at the line you wrote, and an editor completes the call. Write no head for a
query that answers with every match that it holds.

A guard on the head is a test on the left hand side. The query thus holds no match that
fails it, and a call naming a rejected value answers `[]`. The guard is not on the generated
clause, so it may call anything a rule body may call, and not only what an Elixir guard
allows.

A query is identified by `{module, name}`, never by a bare name. Because of this, two
rulesets that each define a `:summary` compose into one session without collision.

When you choose the query at runtime, name the pair. That call takes the **bindings**, and
not the head, because it cannot know the pattern:
`Rete.Session.query(session, {Retail, :large_orders}, cid: 1)`.

### Cancel

```elixir
session =
  session
  |> Rete.Session.insert({:cancelled, 1, 250})
  |> Rete.Session.fire_rules()

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:threshold, 100},
#     {:cancelled, 1, 250},
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:online_order, 2, 30},
#     {:order, 1, 40},
#     {:order, 2, 30},
#     {:placed, 1, 40},
#     {:placed, 1, 250},
#     {:spend, "Ada", 40},
#     {:spend, "Bo", 30}
#   ]
```

The cancellation breaks the match of `live`, so `{:order, 1, 250}` is gone.
`{:large_order, 1, 250}` is gone too. Nothing removed it directly. Its support went away.

`{:spend, "Ada", 290}` is gone, replaced by `{:spend, "Ada", 40}`. The collection is part
of the match, so a different list is a different match.

The placed order stays, because you inserted it. A session keeps what you insert.

Cancel the rest of the orders. The dormancy rules take over:

```elixir
session =
  session
  |> Rete.Session.insert([{:cancelled, 1, 40}, {:cancelled, 2, 30}])
  |> Rete.Session.fire_rules()

Rete.Session.facts(session) |> Enum.sort()
#=> [
#     {:dormant, "Ada"},
#     {:dormant, "Bo"},
#     {:threshold, 100},
#     {:cancelled, 1, 40},
#     {:cancelled, 1, 250},
#     {:cancelled, 2, 30},
#     {:customer, 1, "Ada"},
#     {:customer, 2, "Bo"},
#     {:online_order, 2, 30},
#     {:placed, 1, 40},
#     {:placed, 1, 250},
#     {:spend, "Ada", 0},
#     {:spend, "Bo", 0}
#   ]
```

The `:spend` rule still fires, with an empty list. Its collection introduces no variable of
its own. See the empty-collection rule in [docs/dsl.md](docs/dsl.md) for why.

`:dormant` fires now that the negation holds.

### Ask why

```elixir
Rete.Inspect.explain(session, {Retail, :dormant})
#=> %{
#     rule: :dormant,
#     module: Retail,
#     type: :rule,
#     activations: [
#       %{
#         bindings: %{cid: 1, name: "Ada"},
#         matches: [
#           %{
#             fact: {:customer, 1, "Ada"},
#             origin: :assert,
#             sources: [{Rete.Session, :insert}],
#             members: nil
#           }
#         ],
#         asserts: [{:dormant, "Ada"}]
#       },
#       %{
#         bindings: %{cid: 2, name: "Bo"},
#         matches: [
#           %{
#             fact: {:customer, 2, "Bo"},
#             origin: :assert,
#             sources: [{Rete.Session, :insert}],
#             members: nil
#           }
#         ],
#         asserts: [{:dormant, "Bo"}]
#       }
#     ]
#   }
```

One activation is one match the rule fired on, so two dormant customers give two. Each
entry of `:matches` says where its fact came from. `:sources` names the rules that
concluded it, so you read a chain by following that pair to its own entry.
`{Rete.Session, :insert}` means you inserted the fact. It is a list, because a fact can
have more than one independent support. All of them must go before the fact itself goes.

A collection reports the gathered list under `origin: :gather`, with each member described
in `:members`. That is what the rule received.

`Rete.Inspect` has one other function:

* `why_not/1,2` — how far a rule got, condition by condition

Both take a `{module, name}` pair for one rule or query. Call either with the session alone
for every rule and query at once. Both need a session you have fired.

For history instead of a snapshot, attach `Rete.Listener.Collect` or `Rete.Listener.Trace`.

### Sessions are values

Every operation returns a new session and changes nothing:

```elixir
quiet = Rete.Session.new([Retail]) |> Rete.Session.insert({:customer, 1, "Ada"})
busy = quiet |> Rete.Session.insert({:placed, 1, 250}) |> Rete.Session.fire_rules()
# `quiet` is untouched. Reuse it as a checkpoint.
```

The compiled network is shared, not copied. Because of this, a session is cheap to hold,
cheap to fork, and safe to pass between processes.

Compiling is the expensive part. Do it once, with `Rete.Compiler.build/2`. Start sessions
from the result with `Rete.Session.from_network/1`.

A network calls the ruleset modules by default, so a coverage tool counts the rules, and a
stack trace names `Retail`. A hot upgrade of `Retail` then changes the code that a network
built before it calls. That network can run code of two versions, or raise when it fires.

**If you deploy with hot code upgrades, build with `target_images: true`.** The network
then runs the image of each ruleset module, a copy of its rules that never changes. So it
keeps running the old rules, consistently. Call `Rete.Session.latest?/1` after each
upgrade. It returns `false` when the rules changed, and you then build the network again.
`config :rete, target_images: true` makes this the default.

A dump carries the images either way, so a loaded session keeps its own rules.

### Move a session to another node

`Rete.Session.dump/2` turns a session into a binary. `Rete.Session.load/2` reads it on
another node, which can run another version of your program. Both return `{:ok, value}` or
`{:error, reason}`:

```elixir
{:ok, binary} = Rete.Session.dump(busy, key)

# on the other node
{:ok, session} = Rete.Session.load(binary, key)
Rete.Session.query(session, {Retail, :large_orders}, cid: 1)
```

The binary holds the compiled code of the rules. The loaded session runs **those** rules,
even if the node defines another version of `Retail`, or none. A query keeps its
`{module, name}`, so `Rete.Session.query/3` reaches it on any node. Listeners do not travel,
so attach them again after the load. `dump!/2` and `load!/2` return the plain value, and
raise on an error.

**The key is required.** A snapshot holds code, and loading it runs that code on your
node. So `dump/2` signs every snapshot with an HMAC-SHA256 under the key. `load/2` checks
the signature before it decodes the body, and refuses a snapshot that does not match. Use a
random key, such as `:crypto.strong_rand_bytes(32)`. Keep it in your secret store, apart
from the place that keeps the snapshots.

**A snapshot is signed, not encrypted.** Anyone who has the binary can read the facts in it,
including a conclusion that was retracted. Encrypt the snapshots at rest if the facts are
sensitive.

A rule that calls a function of another module runs the version on the node that loads it.
[docs/design/snapshot.md](docs/design/snapshot.md) has the details and the limits.

## What is public

Eight modules are public:

| module | for |
|---|---|
| `Rete` | aggregating rule, expression and taxonomy data across ruleset modules |
| `Rete.Ruleset` | `defrule`, `defquery`, `derive`, `underive` |
| `Rete.Session` | building a session, inserting, firing, querying, dumping and loading |
| `Rete.Inspect` | `explain/1,2`, `why_not/1,2` |
| `Rete.ActivationCache` | `from_session/2` and `key/1`, to build an activation cache |
| `Rete.Listener` (+ `.Collect`, `.Trace`) | watching what a session does |

**Everything else is internal**: the DSL front end, the IR, the compiler, the network, the
engine, working memory, the agenda, and the value structs.

It is documented, because durability, checkpointing, and tooling will eventually need to
reach in. `docs/design/` carries the reasoning behind it. Semantic versioning does not
cover this internal part. It may change in a patch release. The generated docs group it
under `Internals:` headings for this reason.

One internal struct does reach you through the public API. Every listener event carries a
`Rete.Token`.

**Read its fields freely. Do not depend on its functions.** Expect the field set to change.

## Limitations

Correctness and DSL clarity came first. Several things were left out on purpose. The design
docs under `docs/design/` record why.

* **Collections are collect-all.** `orders = [{:order, cid, amt}]` gathers matching facts
  into a list. There is no accumulator library: no `min`, `max`, `sum`, `count`, and no
  custom accumulators either. Do this work in the right hand side with `Enum` instead.
  Gathering is linear. What a collection costs after that depends on how many members
  arrive per `insert` call — see `docs/dsl.md`.
* **Logical inserts only.** A rule's body returns facts to insert. The engine truth-maintains
  them. There is no unconditional insert and no retract, from a rule or from the session.
  A fact you insert stays. To withdraw a conclusion, insert a fact that the rule reads under
  `{:not, [...]}`. Truth maintenance cascades from the broken match.
* **Firing is a blocking call.** `fire_rules/2` runs to quiescence in the calling process,
  and it returns the settled session. There is no async variant that hands back a `Task`.
  Every rule body runs in the calling process too. A body *can* return a `Task`. Pass
  `:concurrency`, and optionally `:task_timeout`, to `fire_rules/2` to await the tasks of one
  activation group together. A body that blocks without a task never overlaps another — see
  [docs/design/engine.md](docs/design/engine.md) §11.
* **Snapshots carry rules, not data migrations.** `Rete.Session.dump/2` and `load/2` move
  a session to a node that runs other code, and the session keeps its own rules. There is no
  way to move a session onto the **new** rules of that node, and no distributed sync. Images
  that a node loads stay loaded. Snapshots of different releases of rete are not
  guaranteed to be compatible. See [docs/design/snapshot.md](docs/design/snapshot.md).
* **Performance is measured by shape, not tuned for a number.** The algorithm is the right
  one: alpha and beta node sharing across modules as well as within one, hash joins,
  incremental retraction. Two profiling passes have run, and `mix bench` keeps their
  results honest by reporting the empirical exponent of each scenario rather than a
  wall-clock figure. Every scenario is linear.
  [docs/design/engine.md](docs/design/engine.md) §12 lists the known gaps that remain, and
  what each would take to close. What has *not* been done is tuning for absolute
  throughput, or measuring wide disjunctions or memory rather than time.
* **Per-group firing *within* a collection is awkward.** This differs from `salience`,
  which already groups the *agenda* — every activation at one salience tier fires before
  any activation at a lower one. What is awkward is grouping the *facts inside one rule's
  own collection* — one activation per customer's orders, say. This falls out of a
  collection introducing a new variable. Reaching it in practice needs two collections.
  Collect everything instead, and use `Enum.group_by/2`.
* **No rule subsumption or suffix sharing.** Two rules that share a condition prefix share
  nodes, whether they sit in one module or several. Two rules that share only a suffix do
  not.

  One case does not share across modules. A condition whose guard calls an *unqualified*
  function is kept on its own node per module, because the name alone does not say which
  function it means. Qualify the call to share it. See
  [docs/design/ir.md](docs/design/ir.md) §5.

## Development

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

CI runs exactly those, on the declared floor (Elixir 1.18) and on the current release. It
also runs the command below, once, on the current release.

```bash
mix bench
```

Scaling benchmarks report the **empirical exponent**: the k in O(n^k). This is more useful
than a wall-clock figure, since nobody has a baseline for that.

This engine's real failure mode is not a slow function. It is an operation that proves
quadratic in something a session accumulates. A single-size measurement cannot show this.

Each scenario runs at three or four sizes and reports two numbers. The **fit** is k over
every size at once, by least squares, and it is the verdict. The gate on it is `n^1.5`. The
**worst pair** is the steepest step between two sizes, and it is printed to be read.

The *last* step is gated on as well, against a looser bound of `n^1.8`. A fit is an
average, so on its own it would dilute a scenario that stays linear until the largest size
and turns quadratic there. That is the failure this file exists to catch.

Around `~n^1` is fine. `~n^2` is a bug. There is no way to exempt a scenario from either
bound, so one that cannot hold the line is one to fix or to delete.

**The exponent gates CI.** A run that finds a superlinear scenario exits non-zero and names
it. This is safe to gate on because an exponent is a ratio between two timings. The speed of
the machine thus has no effect on it. Run `mix bench` under `ELIXIR_ERL_OPTIONS="+S 2:2"`, or
on a loaded machine, and it reports the same numbers.

CI runs the benchmark **once**, and it does not retry. A scenario that fails now and then
is a scenario sitting too near the gate. Move it away from the gate, or record why it
belongs there.

**Wall-clock thresholds are asserted on nowhere.** On shared runners they fail for reasons
that mean nothing. Every duration `mix bench` prints is there to be read, and not to be
compared against a bound.

## Acknowledgments

**[Clara](https://github.com/gateless/clara-rules)** is the semantic reference for this
engine. When a question about behavior had no obvious answer, Clara's answer became the
specification. Examples of such questions:

* what a negated conjunction means when its conjuncts share a variable
* when the engine may share two nodes
* how truth maintenance interacts with a fact concluded twice

Two of Clara's issues are implemented and regression-tested here:
[issue 433](https://github.com/oracle-samples/clara-rules/issues/433) on node sharing, and
[issue 304](https://github.com/oracle-samples/clara-rules/issues/304) on scoped negation
markers. Both numbers come from Clara's original issue tracker, now at
[oracle-samples/clara-rules](https://github.com/oracle-samples/clara-rules).

This engine ports none of Clara's code. Clara is Clojure on the JVM, and its architecture
reflects that: transient-versus-persistent memory, a transport abstraction, four activation
protocols, and listener calls scattered through every node.

This engine does the BEAM-native thing instead: a flat propagation loop over an explicit
work queue, one immutable memory threaded through a fold, and events emitted in exactly one
place.

**[taxo](https://github.com/rulvio/taxo)** provides the type hierarchies behind `derive`
and `underive`.

## How this was built

This project started as an exploration of the Elixir macro system. It became a passion
project for one reason: Elixir's pattern matching fits a rules engine well. Destructuring,
variable binding, and join identification all come from the argument list. That is what
lets a rule read as a function instead of as a configuration format. That observation
sparked the initial idea for how the DSL and engine are designed.

The architecture and the direction are human, grown from experience building expert systems
with [Clara](https://github.com/gateless/clara-rules), so this project's semantics and
behavior are in some ways similar to Clara's.

**AI disclosure.** AI assistance accelerated the development of this project, under human
direction and review. The design decisions, the semantics, and the trade-offs recorded in
`docs/design/` are the author's.

## License

Apache-2.0. See [LICENSE](LICENSE).
