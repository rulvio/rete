# Writing rules

The reference for the DSL. If you have not met a rules engine before, read the
"how a Rete engine thinks" section of the [README](../README.md) first — the mental model
is the barrier, not the syntax.

## Contents

* [The shape of a rule](#the-shape-of-a-rule)
* [Facts](#facts)
* [Left hand side elements](#left-hand-side-elements)
* [Bindings and joins](#bindings-and-joins)
* [Guards, and where they run](#guards-and-where-they-run)
* [Gates](#gates)
* [Negation](#negation)
* [Collections](#collections)
* [Taxonomy](#taxonomy)
* [Options: salience](#options-salience)
* [Queries](#queries)
* [The right hand side](#the-right-hand-side)
* [Condition order](#condition-order)
* [Limits](#limits)
* [Common mistakes](#common-mistakes)

## The shape of a rule

```elixir
defmodule MyRuleset do
  use Rete.Ruleset

  defrule large_order({:threshold, limit}, {:order, cid, amt} when amt > limit) do
    {:large_order, cid, amt}
  end
end
```

A rule reads as a function. Its **arguments are the left hand side** — the conditions,
matched against facts — and its **body is the right hand side** — the facts that follow
from a match. Pattern matching gives destructuring, variable binding and join-variable
identification for free.

`use Rete.Ruleset` brings in `defrule/2`, `defquery/2`, `derive/2` and `underive/2`, and
makes the module expose the rule, expression and taxonomy data `Rete.Compiler.build/2`
reads. A ruleset module is data, not a process: nothing in it runs until a session
built from it fires.

Two spelling conventions worth adopting: add `import_deps: [:rete]` to your
`.formatter.exs` so that `mix format` keeps `defrule name(...) do ... end` looking like a
declaration instead of rewriting it to `defrule(name(...), do: ...)`.

```elixir
# .formatter.exs
[
  import_deps: [:rete],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

## Facts

A fact is plain data. Three shapes are understood out of the box, and each carries its
own **type** — the thing the alpha index routes on:

| fact | type |
|---|---|
| `{:order, 1, 250}` — a tagged tuple of any arity, including `{:tick}` | `:order` |
| `%MyApp.Order{id: 1}` — a struct | `MyApp.Order` |
| `%{__type__: :order, id: 1}` — a tagged map | `:order` |

Anything else raises when inserted. Typing a fact by accident would make it match
nothing, silently, and there would be no way to tell that from a rule that simply does
not apply. Pass `:fact_type_fn` to `Rete.Session.new/2` if your facts are typed some
other way.

Facts are a **multiset**: inserting the same fact twice needs two retractions to remove
it, and the second insert propagates nothing, because the matches it would make already
exist.

## Left hand side elements

| form | meaning |
|---|---|
| `{:order, cid, amt}` | fact pattern, any arity |
| `{:tick}` | a fact pattern that binds nothing |
| `%Order{id: id}` | struct fact pattern; the type is the module |
| `%{__type__: :order, id: id}` | tagged map fact pattern |
| `o = {:order, cid}` | bind the whole fact to `o` |
| `{:order, amt} when amt > 10` | per-condition guard |
| `o = {:order, amt} when amt > 10` | both |
| `[{:order, cid}]` | collect every matching fact (anonymous) |
| `orders = [{:order, cid}]` | collect every matching fact, bound to `orders` |
| `[{:order, cid, amt} when amt > 10]` | guarded collection |
| `{:not, [{:order, cid}]}` | a gate — `:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor` |
| `%{salience: 100}` **first** | the options map, not a condition |
| `) when <guard> do` | a rule-level guard over every binding |

A worked example using most of them:

```elixir
defrule escalate(
          %{salience: 50},
          c = {:customer, cid, _name},
          {:threshold, limit},
          orders = [{:order, cid, amt} when amt > limit],
          {:not, [{:waived, cid}]}
        )
        when length(orders) > 2 do
  {:escalate, c, length(orders)}
end
```

Read it as: for each customer, given the current threshold, gather that customer's
orders over it; if the customer has no waiver and there are more than two such orders,
conclude an escalation.

A pattern may be as deep as any Elixir pattern — `{:order, cid, %{items: [first | _]}}`
binds `first`. Pinning works too: `^limit`, `^@limit` and `^7` are unwrapped, since a
condition compiles to a standalone function with no enclosing scope for a pin to refer
to. `^amt` becomes `amt`, which is already how this DSL spells a join.

Variables named `_` or `_amt` are discarded, in any position — the same as anywhere else
in Elixir. They do not bind, and a guard cannot read one.

## Bindings and joins

**A variable in two conditions is a join.** There is no join syntax; that is the whole
mechanism:

```elixir
defrule pair({:customer, cid, name}, {:order, cid, amt}) do
  {:pair, name, amt}
end
```

`cid` is bound by the first condition and *constrains* the second, so the rule produces
one match per `(customer, order)` pair that agrees on it. Conditions sharing no variable
are a cartesian product, which is legal and occasionally what you want.

Three kinds of name are worth telling apart:

* a **pattern variable** binds what it matched, and is visible to every later condition,
  to guards and to the right hand side;
* a **fact binding**, the `o` in `o = {:order, cid}`, names the whole fact. It is visible
  downstream but is never a join key — there is nothing upstream for a whole fact to
  equal — so binding one to a name an earlier condition already bound is a compile error
  rather than a silent mis-join;
* a **collection binding**, the `orders` in `orders = [...]`, names the gathered list.

What a rule body may read is exactly what the left hand side can guarantee. A negation
binds nothing downstream; across a disjunction only the variables **every** branch binds
are guaranteed, and one that only some branches bind is `nil` on the others.

## Guards, and where they run

A guard is ordinary Elixir. Where it is *evaluated* decides what it may read, and the
compiler splits it for you, conjunct by conjunct over the top-level `and`/`&&` chain:

| guard | evaluated | may read |
|---|---|---|
| `{:order, amt} when amt > 0` | in the **alpha**, per fact, before any join | the condition's own pattern variables, pinned values, module attributes |
| `{:order, amt} when amt > limit` | in the **join filter**, per candidate pair | the above, plus everything bound upstream |
| `) when length(orders) > 2 do` | in a **test node**, after every condition | every variable the left hand side binds on that path |

```elixir
defrule r({:threshold, t}, {:order, amt} when amt > 0 and amt > t) do
  #                                          ^ alpha    ^ join filter
  {:big, amt}
end
```

Splitting matters because an alpha guard rejects a fact once, when it arrives, while a
join filter runs per candidate pair. A guard that cannot be decomposed — an `or` mixing
local and upstream variables, or one expression touching both sides — goes to the join
filter whole: correctness beats early filtering.

Two rules follow from the table:

* a guard reading a variable that is neither local nor bound upstream is a **compile
  error**, naming the variable and the condition. Left alone it would compile into a
  filter reading a key no token carries, and the rule would silently never fire;
* a **rule-level** guard is checked once per path through the left hand side, so it may
  not read a variable that only some branches of a disjunction bind. Put such a guard on
  the condition inside the branch instead.

## Gates

A gate is `{gate_atom, [element, ...]}`, and its arguments may be any left hand side
elements, including other gates.

| gate | means |
|---|---|
| `{:and, [a, b]}` | all hold |
| `{:or, [a, b]}` | at least one holds |
| `{:not, [a]}` | `a` does not hold |
| `{:not, [a, b]}` | `not (a and b)` — negation of the conjunction |
| `{:nand, [a, b]}` | identical to `{:not, [a, b]}` |
| `{:nor, [a, b]}` | neither holds |
| `{:xor, [a, b, c]}` | **exactly one** holds |
| `{:xnor, [a, b, c]}` | not exactly one holds |

`xor` is "exactly one", not odd parity. For two arguments the two readings agree; from
three up they differ, and "exactly one of these applies" is how the word is used about
rule conditions. A rule that wants parity should nest two-argument `xor`s.

Degenerate arities fall out of applying those definitions literally: a zero-argument
`and` is *true*, a zero-argument `or` is *false*, a one-argument gate is its argument
(or its negation, for the negating gates). A left hand side containing a *false* element
compiles to a rule that can never fire; it is kept rather than dropped, because dropping
it would change what the rule means.

A disjunction fans out into one chain per branch and re-converges on the next condition,
so nesting disjunctions is linear in the number of conditions rather than exponential —
but a single gate that would distribute into more than 256 branches raises at compile
time, naming the gate.

```elixir
defrule contact({:or, [{:email, id, addr}, {:phone, id, addr}]}) do
  {:contactable, id, addr}
end
```

Both branches bind `id` and `addr`, so both are available downstream. Had one branch
bound only `id`, `addr` would be `nil` on that branch and could not be used as a join
key by any later condition.

## Negation

`{:not, [condition]}` propagates a match while **nothing** matches the condition — and
it is scoped to the bindings it shares with the conditions before it:

```elixir
defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
  {:dormant, name}
end
```

This is "this customer has no order", not "there are no orders". The `cid` inside the
negation joins it to the customer.

Two consequences:

* **a negation binds nothing downstream.** There is no matching fact to bind from. A
  right hand side that mentions a variable only a negation names fails to compile with
  `undefined variable`;
* **a negation is not a filter you can run once.** Inserting a matching fact later
  retracts whatever the rule concluded, and retracting the last matching fact lets it
  fire again.

Negating a **conjunction** — `{:nand, [{:order, x}, {:refund, x}]}`, "no `x` has both" —
is supported and is not the same as negating each conjunct. The compiler extracts it
into a generated helper rule that inserts a marker fact carrying the bindings the
negation is scoped by, and negates the marker. You never see the marker:
`Rete.Session.facts/1` hides it and `Rete.Inspect` translates it.

Negating a **disjunction** is de Morganed into a conjunction of negations, which is
always sound.

### Testing that something *does* exist

There is no `exists` gate. Use an empty-tested collection:

```elixir
defrule active({:cust, cid}, os = [{:order, cid, _amt}]) when os != [] do
  {:active, cid}
end
```

That fires **once** per customer with at least one order, which is what existence
means: the collection reduces however many matching facts there are to a single
match.

Do **not** reach for double negation. `{:not, [{:not, [x]}]}` is *not* an existence
test — it collapses to plain `x`:

```elixir
# one match per order, not one per customer
defrule wrong({:cust, cid}, {:not, [{:not, [{:order, cid, _a}]}]}) do
  {:active, cid}
end
```

With two orders that conclusion has **two** supports rather than one, so it takes two
retractions to remove. The fact list hides the difference completely — equal
conclusions collapse into one entry — so this is only visible in the support count or
when something is retracted and refuses to go.

The rewrite is sound propositionally and wrong existentially, which is the same family
of mistake as de Morgan over a conjunction (see `docs/design/ir.md`). The difference
is that de Morgan over a conjunction is caught by the compiler and this is not.

## Collections

`[pattern]` gathers **every** matching fact into a list. This is the engine's only
accumulator and it is always collect-all: there is no `min`, `max`, `sum`, `count` or
custom accumulator. Aggregate in the right hand side with `Enum`.

```elixir
defrule spend({:customer, cid, name}, orders = [{:order, cid, _amt}]) do
  {:spend, name, Enum.sum(for {_, _, amt} <- orders, do: amt)}
end
```

One activation per group, holding the whole list — not one per gathered fact. Change any
member and the list changes, which is a different match: the old conclusion is retracted
and a new one takes its place.

### The empty-collection rule

Whether a collection can match *nothing* depends on whether it introduces a variable of
its own:

* **no new variable** — every variable it uses is already fixed by the match so far.
  There is exactly one group, so it propagates `[]` and the rule fires with an empty
  list. `spend` above fires for a customer with no orders at all, with `orders == []`
  and a sum of `0`;
* **at least one new variable** — it groups by that variable, and a group only exists
  where a fact created it. There is no empty group to invent.

### Collection-local variables

Elixir fuses binding and constraining: writing `amt` in a pattern binds it. Taken
literally that would make a guarded collection impossible — `amt` would be a new
variable, so the collection would group by it and gather one singleton group per
distinct amount.

The rule that resolves it: **a collection's pattern variable participates only if another
condition's pattern also matches on it — a real join. Otherwise it is local to the
collection.**

```elixir
defrule busy_day(os = [{:order, cid, day, amt} when amt > 100]) do
  {:busy, length(os)}
end
```

`amt` and `day` are local: they constrain which facts are gathered, group nothing, and
bind nothing downstream. Reading one outside its collection is a compile error naming
the variable and the collection, because every gathered fact has its own value and there
is no one value to bind.

Only another **pattern** counts as participation — not another condition's guard, not
this collection's own guard, not the rule-level `when`, not the right hand side, and not
a negation's pattern (a negation binds nothing, so it is not a join).

### Getting one activation per group

Because a plain condition matching the variable sorts *before* the collection (see
[condition order](#condition-order)), it makes the variable an ordinary join key rather
than a grouping variable. Grouping therefore arises in practice between **two**
collections, where both are deferred and the first groups by what the second joins on.
The straightforward alternative is to collect everything and `Enum.group_by/2` in the
right hand side, which yields one fact holding a map rather than one activation per
group.

### Order is unspecified

**A rule may not depend on the order of the list it receives.** Sort in the right hand
side if order matters. The engine does keep collections deterministically ordered, so
that the same facts always produce the same list whatever order they arrived in, but
that order is term order and is not a contract.

## Taxonomy

`derive/2` says one fact type *is a* kind of another, so that a rule written against the
general type also sees the specific one:

```elixir
derive :premium, :customer
derive :online_order, :order
```

A `:premium` fact now reaches every condition written against `:customer`. The reverse
does not hold — not every customer is premium. Derivation is transitive, and `underive/2`
removes a relation declared earlier (order matters: declarations are folded in module
order, and a module can only undo what a module before it declared).

Taxonomy is applied by the **alpha index** and nowhere else. An alpha expression matches
a fact of any type on purpose; which alphas a fact reaches is decided from its type and
its derived ancestors. That is why widening a hierarchy does not recompile a single
expression.

Struct types work the same way, with the module as the type: `derive MyApp.Refund,
MyApp.Adjustment`.

## Options: salience

A `%{...}` literal in **first** position is the rule's options, not a condition — unless
it has a `__type__` key, which makes it a tagged-map condition instead.

```elixir
defrule urgent(%{salience: 100}, {:alarm, id}) do
  {:page, id}
end
```

| key | meaning |
|---|---|
| `:salience` | firing priority, default `0`. Higher fires first. |

Activations fire in `salience` order, descending; ties break on the order the rules were
defined in. Salience orders *firing*, not matching — every rule whose left hand side
holds will fire eventually, and by the time `fire_rules/2` returns the session is
consistent regardless. Reach for it when a rule must observe the conclusions of another,
not as a control-flow mechanism.

`:internal_salience` is reserved: the compiler uses it to make an extracted negation
helper run before the rule that negates its marker, and setting it yourself raises.
Other keys in the map are ignored.

## Queries

A query has the same left hand side as a rule. It never fires; you read it, and **its
body is what you get** — one result per match, shaped however you like.

```elixir
defquery large_orders({:large_order, cid, amt}) do
  {cid, amt}
end

defquery summary({:customer, cid, name}, orders = [{:large_order, cid, amt}]) do
  %{customer: name, count: length(orders)}
end
```

**A query is a function in its own module.** `defquery large_orders(...)` defines
`large_orders/1` and `large_orders/2`, so you run it by calling it:

```elixir
MyRuleset.large_orders(session)                    #=> [{1, 250}, {1, 900}, {2, 30}]
MyRuleset.large_orders(session, cid: 1)            #=> [{1, 250}, {1, 900}]
MyRuleset.large_orders(session, cid: 1, amt: 250)  #=> [{1, 250}]
MyRuleset.large_orders(session, %{cid: 2})         #=> [{2, 30}]
MyRuleset.summary(session)                         #=> [%{customer: "Ada", count: 2}]

session |> MyRuleset.large_orders(cid: 1)          # a plain function, so it pipes
```

There is nothing to declare. Any variable the left hand side binds can be constrained at
call time, as a keyword list or a map. Naming something the query does not bind raises,
listing what it does bind, rather than quietly answering `[]`:

```elixir
MyRuleset.large_orders(session, nope: 1)
#=> ** (ArgumentError) the query MyRuleset.large_orders binds [:amt, :cid], and was given [:nope]
```

### Two rulesets may use the same query name

A query is identified by **module and name together**, never by the name alone. Two
rulesets that each define a `:summary` compose into one session without collision, and
`MyRuleset.summary(session)` is unambiguous by construction — it is an ordinary function
call, so a typo is a compile error rather than an empty result at runtime.

When the query is not known until it runs, name it with the pair:

```elixir
Rete.Session.query(session, {MyRuleset, :large_orders}, cid: 1)

for q <- [:large_orders, :summary], do: Rete.Session.query(session, {MyRuleset, q})
```

That is the whole of the addressing scheme: **call it, or name it with `{module, name}`.**
A bare `:large_orders` is rejected, with an error pointing at both forms. The same pair
names a rule for `Rete.Inspect.why_not/2`.

This is where the engine differs from Clara, deliberately, in two ways. Clara declares a
query's parameters up front and uses them to key the query node's memory, so a lookup is
a hash lookup; here a filter is applied to the matches at the terminal, which means the
caller is not restricted to a fixed set of keys and can slice a query however they like
without redeclaring it. And Clara's `defquery` binds a var that you pass to `query`,
where Elixir's module system already gives every query a home and a name — so the query
*is* the function.

Two things to know:

* filtering happens on the **bindings**, before the body runs. That is what makes a
  filter name a variable rather than a shape of the result, so you can filter on
  something the body never returns;
* a query reads the session as it stands. Query one with pending activations and you see
  what was true before they fired.

Row order is unspecified. It does not vary with the order facts were inserted in, so a
given set of facts always answers the same way, but sort the result if the order matters.

## The right hand side

The body of a rule computes the facts that follow from the match. It may return:

| returned | inserted |
|---|---|
| `{:large_order, cid, amt}` | that one fact |
| `[{:a, 1}, {:b, 2}]` | both |
| `nil` | nothing |
| `[]` | nothing |
| `[{:a, 1}, nil]` | just `{:a, 1}` — `nil`s in a list are dropped |

so a conditional conclusion is just an `if` with no `else`.

Everything it returns is inserted **logically**: the engine records which match produced
it, and takes it back when that match stops holding. That is why there is no
unconditional insert and no retract from a rule — keeping a conclusion true as facts
change is the engine's job.

Two consequences that surprise people:

* **a conclusion cannot hold itself up.** A rule whose match already rests on the fact it
  concludes does not give that fact a second support, so retracting what you inserted
  really does empty the session. `symmetric({:edge, a, b}) -> {:edge, b, a}` does not
  leave two immortal facts behind;
* **a rule that concludes something its own left hand side matches on will loop.**
  `fire_rules/2` runs to quiescence and does not cap activations unless you ask
  (`:max_cycles`, `:infinity` by default). Give it an integer and it raises,
  leading with which rules fired most.

The body may read only the variables the left hand side binds on the path that reached
it. It runs in the ruleset module, so it may call that module's functions, and nothing
orders it against anything else except salience.

### A body may run more than once

Its **return value** is truth maintained, so nothing is concluded twice. A **side effect**
is not, and there are two ways one can happen more often than the conclusions suggest:

* retracting and reinserting the facts behind a match runs the body again for that match;
* under `fire_rules(session, concurrency: n)` the bodies of one activation group run at
  once, so a body may run for a match that another activation *in the same group* then
  invalidates. That activation does not fire — nothing it computed is inserted, exactly as
  if the bodies had run one at a time — but a request it already sent is sent.

A body that only computes facts is therefore safe to write however you like. One that
writes to a database or calls a service should be idempotent and expect at-least-once.

Raising `:concurrency` above its default of `1` is worth it only when the body is
expensive — I/O, or real computation. A body that builds a tuple is about 1.5% of firing
and costs more than that to hand to a task.

Two things follow from a body running on a task. `Logger.metadata` is not inherited, so
read it before firing if the body logs. And the bindings are copied, which is free for
scalars but not for a **collection binding**: handing a 2,000-element list to each task
made one benchmark 16× slower. See `docs/design/engine.md` §11.

## Condition order

Write conditions in the order that reads best. The compiler sorts them topologically, so
that a condition only ever comes after the ones binding the variables it needs:

```elixir
defrule r({:order, amt} when amt > t, {:threshold, t}) do
  {:big, amt}
end
```

compiles exactly as if the threshold had been written first. The sort is **stable** —
conditions that are equally satisfiable keep the order they were written in, which is
what lets two rules sharing a prefix share their alpha and join nodes.

Two kinds of element are deliberately deferred to the end: **collections**, because one
placed too early would propagate `[]` before the conditions that would have filled it
were joined, and **rule-level guards**, which bind nothing so nothing can wait on them.

If no ordering works — usually a typo in a variable name — the error names the rule, the
conditions it could not place and exactly which variables are unbound.

## Limits

| limit | value | what happens |
|---|---|---|
| branches from one gate | 256 | `ArgumentError` at compile time, naming the gate |
| activations per `fire_rules/2` | uncapped; `:max_cycles` to bound it | `RuntimeError` leading with the rules that fired most |

The branch limit is about compile time: distribution is the one step that can explode, a
conjunction of `k` disjunctions of `m` branches being `m^k`. Negation is linear and is
not a source of growth.

## Common mistakes

### Referencing a variable no condition binds

```elixir
defrule r({:order, cid, amt}) when tier > 1 do
  {:x, cid}
end
```

```
** (ArgumentError) the rule level guard `tier > 1` reads `tier`, which no condition
binds on this path through the left hand side. ...
```

A guard may only read what the left hand side binds *where the guard runs*. The same
mistake inside a per-condition guard is caught by the condition sort instead, which
reports which conditions it could not place and what they needed:

```
** (ArgumentError) the left hand side of `defrule r` in MyApp cannot be ordered: none
of the 1 remaining conditions can be satisfied.

Unbound: `limt`
```

### A fact binding that shadows an upstream variable

```elixir
defrule r({:lim, t}, t = {:order, amt}) do
  {:x, amt}
end
```

```
** (ArgumentError) the condition {:order, amt} is bound to `t`, but `t` is already
bound by an earlier condition. ...
```

A fact binding names the whole fact, so it cannot join against an upstream value of the
same name — a guard reading `t` would compare an integer against a tuple, which Erlang
term order makes false for every fact, and the rule would never fire with nothing to
report it. Rename the binding.

### Expecting a negation to bind variables downstream

```elixir
defrule r({:customer, cid}, {:not, [{:order, cid, amt}]}) do
  {:x, cid, amt}
end
```

```
** (CompileError) undefined variable "amt"
```

There is no matching fact, so there is nothing to bind `amt` to. The `cid` inside the
negation is *read*, to scope the negation to this customer; `amt` is existentially
quantified and does not escape. If you want the amount, you want a match, not a negation.

### Expecting a rule to fire before `fire_rules/2`

```elixir
session = Rete.Session.insert(session, {:order, 1, 250})
Rete.Session.facts(session)  #=> just the order; no conclusions
```

Inserting propagates matches and queues activations. Nothing runs until `fire_rules/2`,
which is what lets a batch of facts be reasoned about together. `Rete.Session.pending/1`
shows what is waiting. The same applies to querying: a query answered before firing tells
you what was true before.

### Reading a collection-local variable outside its collection

```elixir
defrule r(os = [{:order, cid, amt} when amt > 10]) do
  {:x, amt, length(os)}
end
```

```
** (ArgumentError) the right hand side of `r` reads `amt`, which is local to the
collection `os = [{:order, cid, amt} when amt > 10]`.

Every fact the collection gathers has its own `amt`, so there is no one value to bind
outside it. ...
```

Either add a condition whose pattern matches on `amt`, so the collection groups by it, or
take it from the gathered facts: `for {_, _, amt} <- os, do: amt`.

### Expecting two productions of one name to be clauses

```elixir
defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid, amt}
defrule flag({:ticket, cid}), do: {:flagged, cid, :ticket}
```

```
** (ArgumentError) lib/rules.ex:4: defrule flag repeats a name already declared in
MyApp.Rules — defrule flag, lib/rules.ex:3. ...
```

Elixir function clauses are ordered alternatives: the first one that matches wins and
the rest never run. Productions are not. **Every** rule whose left hand side holds fires,
and a query answers from every match, so two of one name would both apply — which is
almost never what the clause syntax leads you to expect. Rules and queries share one
namespace, so a `defrule thing` and a `defquery thing` collide too.

Within a module a name must be unique; across modules it need not be, since a production
is identified by `{module, name}`. If you wanted alternatives, write one production over
a disjunction — the branches may bind different variables, and one that only some
branches bind is `nil` in the body:

```elixir
defrule flag({:or, [{:order, cid, amt}, {:ticket, cid}]}) do
  {:flagged, cid, amt || :from_ticket}
end
```

If you wanted them scheduled separately or told apart in `Rete.Inspect.fired/2`, give
them different names — that is what a name is for.

### Others worth knowing

| mistake | what you get |
|---|---|
| `defrule r({:order, cid})` with no `do` block | an error naming the rule; the body is the point of a rule |
| `{:order, _amt} when _amt > 0` | an error saying to rename it to `amt`; `_`-prefixed names are discarded |
| `[f = {:order, cid}]` | an error: bind the whole collection, not an element of it |
| `defquery q(%{params: [:cid]}, {:a, cid})` | an error: `params` no longer exists, any binding can be filtered on |
| `@limit 5` … rule … `@limit 100` … same condition | an error: two conditions that read the same attribute at different values cannot share one compiled function |
