# Writing rules

This is the reference for the DSL. If you have not used a rules engine before, read the
"How a Rete engine thinks" section of the [README](../README.md) first. The mental model
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

A rule reads as a function. Its **arguments are the left hand side**: the conditions,
matched against facts. Its **body is the right hand side**: the facts that follow from a
match. Pattern matching gives you destructuring, variable binding, and join-variable
identification for free.

`use Rete.Ruleset` brings in `defrule/2`, `defquery/2`, `derive/2`, and `underive/2`. It
also makes the module expose the rule, expression, and taxonomy data that
`Rete.Compiler.build/2` reads. A ruleset module is data, not a process. Nothing in it runs
until a session built from it fires.

There are two spelling conventions worth adopting. Add `import_deps: [:rete]` to your
`.formatter.exs`. This keeps `mix format` from rewriting `defrule name(...) do ... end`
into `defrule(name(...), do: ...)`.

```elixir
# .formatter.exs
[
  import_deps: [:rete],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

## Facts

A fact is plain data. The engine understands three shapes out of the box. Each carries its
own **type**: the thing the alpha index routes on:

| fact | type |
|---|---|
| `{:order, 1, 250}` — a tagged tuple of any arity, including `{:tick}` | `:order` |
| `%MyApp.Order{id: 1}` — a struct | `MyApp.Order` |
| `%{__type__: :order, id: 1}` — a tagged map | `:order` |

Anything else raises an error when inserted. If a fact had the wrong type by accident, it
would match nothing, silently. You could not tell that case apart from a rule that simply
does not apply. Pass `:fact_type_fn` to `Rete.Session.new/2` if your facts use some other
typing scheme.

Facts form a **multiset**. Inserting the same fact twice needs two retractions to remove
it. The second insert propagates nothing, because the matches it would make already exist.

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

Read it this way: for each customer, given the current threshold, gather that customer's
orders above it. If the customer has no waiver, and there are more than two such orders,
conclude an escalation.

A pattern may be as deep as any Elixir pattern. For example, `{:order, cid, %{items:
[first | _]}}` binds `first`.

Pinning works too. `^limit`, `^@limit`, and `^7` are unwrapped, because a condition
compiles to a standalone function with no enclosing scope for a pin to refer to. `^amt`
becomes plain `amt`, which is already how this DSL spells a join.

Variables named `_` or `_amt` are discarded, in any position, the same as anywhere else in
Elixir. They do not bind. A guard cannot read one.

## Bindings and joins

**A variable in two conditions is a join.** There is no join syntax. This is the whole
mechanism:

```elixir
defrule pair({:customer, cid, name}, {:order, cid, amt}) do
  {:pair, name, amt}
end
```

The first condition binds `cid`, and it *constrains* the second condition. So the rule
produces one match per `(customer, order)` pair that agrees on `cid`.

Conditions that share no variable form a cartesian product. This is legal, and
occasionally it is what you want.

Three kinds of name are worth telling apart:

* a **pattern variable** binds what it matched. It is visible to every later condition, to
  guards, and to the right hand side.
* a **fact binding** — the `o` in `o = {:order, cid}` — names the whole fact. It is
  visible downstream, but it is never a join key, since there is nothing upstream for a
  whole fact to equal. Binding one to a name an earlier condition already bound is a
  compile error, not a silent mis-join.
* a **collection binding** — the `orders` in `orders = [...]` — names the gathered list.

A rule body may read only what the left hand side can guarantee. A negation binds nothing
downstream. Across a disjunction, only the variables **every** branch binds are
guaranteed. A variable that only some branches bind is `nil` on the others.

## Guards, and where they run

A guard is ordinary Elixir. Where it is *evaluated* decides what it may read. The compiler
splits the guard for you, conjunct by conjunct, over the top-level `and`/`&&` chain:

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

Splitting matters because an alpha guard rejects a fact once, when the fact arrives. A
join filter, in contrast, runs once per candidate pair.

A guard that the compiler cannot split — an `or` mixing local and upstream variables, or
one expression touching both sides — goes to the join filter whole. Correctness beats
early filtering here.

Two rules follow from the table:

* a guard that reads a variable that is neither local nor bound upstream is a **compile
  error**. The error names the variable and the condition. Left uncaught, it would compile
  into a filter that reads a key no token carries, and the rule would silently never fire.
* a **rule-level** guard runs once per path through the left hand side. So it may not read
  a variable that only some branches of a disjunction bind. Put a guard like this on the
  condition inside the branch instead.

## Gates

A gate is `{gate_atom, [element, ...]}`. Its arguments may be any left hand side elements,
including other gates.

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

`xor` means "exactly one", not odd parity. For two arguments, the two readings agree. From
three arguments up, they differ. "Exactly one of these applies" is how the word is used
for rule conditions here. A rule that wants parity should nest two-argument `xor`s
instead.

Degenerate arities follow from applying those definitions literally. A zero-argument `and`
is *true*. A zero-argument `or` is *false*. A one-argument gate is its argument — or its
negation, for the negating gates.

A left hand side containing a *false* element compiles to a rule that can never fire. The
compiler keeps it rather than dropping it, because dropping it would change what the rule
means.

A disjunction fans out into one chain per branch, then re-converges on the next condition.
Because of this, nesting disjunctions costs work linear in the number of conditions, not
exponential.

But a single gate that would distribute into more than 256 branches raises an error at
compile time, naming the gate.

```elixir
defrule contact({:or, [{:email, id, addr}, {:phone, id, addr}]}) do
  {:contactable, id, addr}
end
```

Both branches bind `id` and `addr`, so both variables are available downstream. If one
branch had bound only `id`, `addr` would be `nil` on that branch. No later condition could
then use `addr` as a join key.

## Negation

`{:not, [condition]}` propagates a match while **nothing** matches the condition. It is
scoped to the bindings it shares with the conditions before it:

```elixir
defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
  {:dormant, name}
end
```

This means "this customer has no order," not "there are no orders at all." The `cid`
inside the negation joins the negation to the customer.

Two consequences:

* **a negation binds nothing downstream.** There is no matching fact to bind from. A right
  hand side that mentions a variable only a negation names fails to compile, with
  `undefined variable`.
* **a negation is not a filter you can run once.** Inserting a matching fact later
  retracts whatever the rule concluded. Retracting the last matching fact lets the rule
  fire again.

Negating a **conjunction** is supported: `{:nand, [{:order, x}, {:refund, x}]}` means "no
`x` has both". This is not the same as negating each conjunct separately.

The compiler extracts a negated conjunction into a generated helper rule. That helper
inserts a marker fact carrying the bindings the negation is scoped by, then negates the
marker. You never see the marker yourself: `Rete.Session.facts/1` hides it, and
`Rete.Inspect` translates it.

Negating a **disjunction** turns into a conjunction of negations, by De Morgan's law. This
transform is always sound.

### Testing that something *does* exist

There is no `exists` gate. Use an empty-tested collection:

```elixir
defrule active({:cust, cid}, os = [{:order, cid, _amt}]) when os != [] do
  {:active, cid}
end
```

This fires **once** per customer with at least one order. That is what existence means
here: the collection reduces however many matching facts exist to a single match.

Do **not** use double negation for this. `{:not, [{:not, [x]}]}` is *not* an existence
test. It collapses to plain `x`:

```elixir
# one match per order, not one per customer
defrule wrong({:cust, cid}, {:not, [{:not, [{:order, cid, _a}]}]}) do
  {:active, cid}
end
```

With two orders, that conclusion has **two** supports instead of one. It then takes two
retractions to remove.

The fact list hides this difference completely, because equal conclusions collapse into
one entry. You can only see the difference in the support count, or when something is
retracted and refuses to disappear.

This rewrite is sound as propositional logic, but wrong for existence. It is the same
family of mistake as applying De Morgan's law over a conjunction — see
`docs/design/ir.md`.

The difference: the compiler catches the De Morgan mistake over a conjunction. It does not
catch this one.

## Collections

`[pattern]` gathers **every** matching fact into a list. This is the engine's only
accumulator, and it is always collect-all. There is no `min`, `max`, `sum`, `count`, or
custom accumulator. Aggregate the list in the right hand side, with `Enum`.

```elixir
defrule spend({:customer, cid, name}, orders = [{:order, cid, _amt}]) do
  {:spend, name, Enum.sum(for {_, _, amt} <- orders, do: amt)}
end
```

There is one activation per group, holding the whole list, not one activation per gathered
fact. Change any member, and the list changes. A different list is a different match, so
the old conclusion is retracted and a new one takes its place.

### The empty-collection rule

Whether a collection can match *nothing* depends on whether it introduces a variable of
its own:

* **no new variable.** Every variable it uses is already fixed by the match so far. There
  is exactly one group, so it propagates `[]`, and the rule fires with an empty list.
  `spend` above fires for a customer with no orders at all, with `orders == []` and a sum
  of `0`.
* **at least one new variable.** It groups by that variable, and a group exists only where
  a fact created it. There is no empty group to invent.

### Collection-local variables

Elixir fuses binding and constraining. Writing `amt` in a pattern binds it. Taken
literally, this would make a guarded collection impossible: `amt` would be a new variable,
so the collection would group by it. It would gather one singleton group per distinct
amount.

The rule that resolves this: **a collection's pattern variable participates only if
another condition's pattern also matches on it — a real join. Otherwise the variable is
local to the collection.**

```elixir
defrule busy_day(os = [{:order, cid, day, amt} when amt > 100]) do
  {:busy, length(os)}
end
```

`amt` and `day` are local. They constrain which facts are gathered. They group nothing,
and they bind nothing downstream. Reading one outside its collection is a compile error,
naming the variable and the collection. Every gathered fact has its own value, so there is
no single value to bind.

Only another **pattern** counts as participation. None of these count:

* another condition's guard
* this collection's own guard
* the rule-level `when`
* the right hand side
* a negation's pattern — a negation binds nothing, so it is not a join

### Getting one activation per group

A plain condition that matches the variable sorts *before* the collection (see [condition
order](#condition-order)). This makes the variable an ordinary join key, not a grouping
variable.

Grouping therefore arises in practice only between **two** collections. Both are deferred,
and the first groups by what the second joins on.

The straightforward alternative: collect everything, then use `Enum.group_by/2` in the
right hand side. This yields one fact holding a map, instead of one activation per group.

### Order is unspecified

**A rule may not depend on the order of the list it receives.** Sort the list in the right
hand side, if order matters to you.

This is a real warning, not a formality. A collection gathers in **reverse arrival order**,
so the same facts fed in a different order produce a different list, and a member retracted
and re-inserted comes back at the front. A rule that reduces its collection to something
order-insensitive — `length`, a sum, a set — is unaffected. A rule that puts the list itself
into a fact, or reads `hd/1`, is not:

```elixir
defrule totals({:customer, cid}, orders = [{:order, cid, _amt}]) do
  {:total, cid, Enum.sum(for {_, _, amt} <- orders, do: amt)}   # fine
end

defrule biggest({:customer, cid}, orders = [{:order, cid, _amt}]) do
  {:biggest, cid, hd(orders)}                                    # depends on the feed
end
```

The engine used to sort collections internally, so that `biggest` above happened to be
stable. Do not rely on that returning: it cost a pass over the group every time a member
changed, quadratic over the group's lifetime, to prop up the one kind of rule this section
tells you not to write. Sorting in the right hand side costs a pass each time the rule
*fires* instead — paid by the rules that need it, when they need it.

## Taxonomy

`derive/2` says one fact type *is a* kind of another. Because of this, a rule written
against the general type also sees the specific one:

```elixir
derive :premium, :customer
derive :online_order, :order
```

A `:premium` fact now reaches every condition written against `:customer`. The reverse
does not hold: not every customer is premium.

Derivation is transitive. `underive/2` removes a relation declared earlier. Order matters
here: the compiler folds declarations in module order, so a module can only undo what an
earlier module declared.

Only the **alpha index** applies taxonomy. An alpha expression matches a fact of any type,
on purpose. A fact's type, and its derived ancestors, decide which alphas the fact
reaches. That is why widening a hierarchy never recompiles a single expression.

Struct types work the same way, with the module as the type: `derive MyApp.Refund,
MyApp.Adjustment`.

## Options: salience

A `%{...}` literal in **first** position is the rule's options, not a condition. The
exception: a `__type__` key makes it a tagged-map condition instead.

```elixir
defrule urgent(%{salience: 100}, {:alarm, id}) do
  {:page, id}
end
```

| key | meaning |
|---|---|
| `:salience` | firing priority, default `0`. Higher fires first. |

Activations fire in `salience` order, descending. Ties break on the order the rules were
defined in.

Salience orders *firing*, not matching. Every rule whose left hand side holds fires
eventually. By the time `fire_rules/2` returns, the session is consistent regardless of
firing order. Use salience when a rule must observe the conclusions of another rule, not
as a general control-flow mechanism.

`:internal_salience` is reserved. The compiler uses it to make an extracted negation
helper run before the rule that negates its marker. Setting `:internal_salience` yourself
raises an error. The map ignores any other key.

## Queries

A query has the same left hand side as a rule. It never fires. You read it instead, and
**its body is what you get**: one result per match, shaped however you like.

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

There is nothing to declare. You can constrain any variable the left hand side binds, at
call time, as a keyword list or a map. Naming something the query does not bind raises an
error instead of quietly answering `[]`. The error lists what the query does bind:

```elixir
MyRuleset.large_orders(session, nope: 1)
#=> ** (ArgumentError) the query MyRuleset.large_orders binds [:amt, :cid], and was given [:nope]
```

### Two rulesets may use the same query name

A query is identified by **module and name together**, never by the name alone. Because of
this, two rulesets that each define a `:summary` compose into one session without
collision. `MyRuleset.summary(session)` is unambiguous by construction, since it is an
ordinary function call. A typo here is a compile error, not an empty result at runtime.

When the query is not known until it runs, name it with the pair:

```elixir
Rete.Session.query(session, {MyRuleset, :large_orders}, cid: 1)

for q <- [:large_orders, :summary], do: Rete.Session.query(session, {MyRuleset, q})
```

That is the whole addressing scheme: **call the query, or name it with `{module,
name}`.** A bare `:large_orders` is rejected. The error points at both forms. The same
`{module, name}` pair also names a rule for `Rete.Inspect.why_not/2`.

This engine differs from Clara here, deliberately, in two ways:

1. Clara declares a query's parameters up front, and uses them to key the query node's
   memory, so a lookup is a hash lookup. Here, a filter runs on the matches at the
   terminal instead. This means you are not restricted to a fixed set of keys, and you can
   slice a query however you like, without redeclaring it.
2. Clara's `defquery` binds a variable that you pass to `query`. Elixir's module system
   already gives every query a home and a name, so here the query *is* the function.

Two things to know:

* filtering happens on the **bindings**, before the body runs. So a filter names a
  variable, not a shape of the result. You can filter on something the body never
  returns.
* a query reads the session as it stands. If you query one with pending activations, you
  see what was true before they fired.

Row order is unspecified. It does not vary with the order facts were inserted in, so a
given set of facts always answers the same way. Sort the result yourself if order matters
to you.

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

The engine inserts everything the body returns **logically**. It records which match
produced each fact, and takes the fact back when that match stops holding. That is why
there is no unconditional insert, and no retract from a rule. Keeping a conclusion true as
facts change is the engine's job, not yours.

Two consequences surprise people:

* **a conclusion cannot hold itself up.** If a rule's match already rests on the fact it
  concludes, that fact does not get a second support. So retracting what you inserted
  really does empty the session. `symmetric({:edge, a, b}) -> {:edge, b, a}` does not
  leave two immortal facts behind.
* **a rule that concludes something its own left hand side matches on will loop.**
  `fire_rules/2` runs to quiescence, and it does not cap activations unless you ask it to.
  Pass `:max_cycles` for a cap — it defaults to `:infinity`. Give it an integer, and it
  raises an error naming the rules that fired most.

The body may read only the variables the left hand side binds, on the path that reached
it. It runs inside the ruleset module, so it may call that module's functions. Nothing
orders it against any other rule, except salience.

### A body may run more than once

The engine truth-maintains the body's **return value**, so nothing gets concluded twice.
It does not truth-maintain a **side effect**. A side effect can happen more often than the
conclusions suggest, in two ways:

* retracting and reinserting the facts behind a match runs the body again, for that match.
* under `fire_rules(session, concurrency: n)`, the bodies of one activation group run at
  once. So a body may run for a match that another activation *in the same group* then
  invalidates. That activation does not fire, and the engine inserts nothing it computed —
  exactly as if the bodies had run one at a time. But a request the body already sent
  still went out.

A body that only computes facts is safe to write however you like. One that writes to a
database, or calls a service, should be idempotent, and it should expect at-least-once
execution.

Raising `:concurrency` above its default of `1` is worth it only when the body is
expensive: I/O, or real computation. A body that just builds a tuple costs about 1.5% of
firing — and handing it to a task costs more than that.

Two things follow from a body running on a task.

`Logger.metadata` is not inherited. Read it before firing, if the body logs.

The engine also copies the bindings to the task. This is free for scalars, but not for a
**collection binding**: handing a 2,000-element list to each task made one benchmark 16×
slower. See `docs/design/engine.md` §11.

## Condition order

Write conditions in the order that reads best. The compiler sorts them topologically. A
condition then comes only after the ones that bind the variables it needs:

```elixir
defrule r({:order, amt} when amt > t, {:threshold, t}) do
  {:big, amt}
end
```

This compiles exactly as if the threshold had been written first. The sort is **stable**:
conditions that are equally satisfiable keep the order they were written in. This is what
lets two rules that share a prefix share their alpha and join nodes.

Two kinds of element are deliberately deferred to the end:

* **collections.** One placed too early would propagate `[]` before the conditions that
  would have filled it were joined.
* **rule-level guards.** They bind nothing, so nothing can wait on them.

If no ordering works — usually because of a typo in a variable name — the error names the
rule. It also names the conditions it could not place, and exactly which variables are
unbound.

## Limits

| limit | value | what happens |
|---|---|---|
| branches from one gate | 256 | `ArgumentError` at compile time, naming the gate |
| activations per `fire_rules/2` | uncapped; `:max_cycles` to bound it | `RuntimeError` leading with the rules that fired most |

The branch limit is about compile time. Distribution is the one step that can explode: a
conjunction of `k` disjunctions of `m` branches becomes `m^k`. Negation is linear, and it
is not a source of growth.

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

A guard may only read what the left hand side binds, *where the guard runs*. The
condition sort catches the same mistake inside a per-condition guard instead. It reports
which conditions it could not place, and what they needed:

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
same name. A guard reading `t` would compare an integer against a tuple. Erlang term order
makes that comparison false for every fact. The rule would then never fire, with nothing
to report why. Rename the binding instead.

### Expecting a negation to bind variables downstream

```elixir
defrule r({:customer, cid}, {:not, [{:order, cid, amt}]}) do
  {:x, cid, amt}
end
```

```
** (CompileError) undefined variable "amt"
```

There is no matching fact, so there is nothing to bind `amt` to. The negation *reads*
`cid`, to scope itself to this customer. `amt` is existentially quantified, so it does not
escape the negation. If you want the amount, write a match instead of a negation.

### Expecting a rule to fire before `fire_rules/2`

```elixir
session = Rete.Session.insert(session, {:order, 1, 250})
Rete.Session.facts(session)  #=> just the order; no conclusions
```

Inserting propagates matches and queues activations. Nothing runs until `fire_rules/2`.
This is what lets you reason about a batch of facts together. `Rete.Session.pending/1`
shows what is waiting.

The same applies to querying. A query answered before firing tells you what was true
before firing.

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

You have two options. Add a condition whose pattern matches on `amt`, so the collection
groups by it. Or take `amt` from the gathered facts instead: `for {_, _, amt} <- os, do:
amt`.

### Expecting two productions of one name to be clauses

```elixir
defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid, amt}
defrule flag({:ticket, cid}), do: {:flagged, cid, :ticket}
```

```
** (ArgumentError) lib/rules.ex:4: defrule flag repeats a name already declared in
MyApp.Rules — defrule flag, lib/rules.ex:3. ...
```

Elixir function clauses are ordered alternatives. The first one that matches wins, and the
rest never run. Productions do not work this way. **Every** rule whose left hand side
holds fires. A query answers from every match. So two productions of one name would both
apply — almost never what the clause syntax leads you to expect. Rules and queries share
one namespace, so a `defrule thing` and a `defquery thing` collide too.

Within one module, a name must be unique. Across modules it need not be, since a
production is identified by `{module, name}`.

If you wanted alternatives, write one production over a disjunction instead. The branches
may bind different variables. A variable that only some branches bind is `nil` in the
body:

```elixir
defrule flag({:or, [{:order, cid, amt}, {:ticket, cid}]}) do
  {:flagged, cid, amt || :from_ticket}
end
```

If you wanted the rules scheduled separately, or told apart in `Rete.Inspect.fired/2`,
give them different names instead. That is what a name is for.

### Others worth knowing

| mistake | what you get |
|---|---|
| `defrule r({:order, cid})` with no `do` block | an error naming the rule; the body is the point of a rule |
| `{:order, _amt} when _amt > 0` | an error saying to rename it to `amt`; `_`-prefixed names are discarded |
| `[f = {:order, cid}]` | an error: bind the whole collection, not an element of it |
| `defquery q(%{params: [:cid]}, {:a, cid})` | an error: `params` no longer exists, any binding can be filtered on |
| `@limit 5` … rule … `@limit 100` … same condition | an error: two conditions that read the same attribute at different values cannot share one compiled function |
