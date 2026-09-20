# Writing rules

This is the reference for the DSL. If you have not used a rules engine before, read the
"How a Rete engine thinks" section of the [README](../README.md) first. The model is more
difficult to learn than the syntax.

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
* [Options: salience and meta](#options-salience-and-meta)
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
| `%MyApp.Order{__type__: :vip, id: 1}` — a struct that declares one | `:vip` |

A **`__type__` always takes precedence**, on a struct as well. It is an explicit
declaration, and a declaration outranks the module.

In a *condition*, writing both means both. `%Order{__type__: :vip, id: id}` matches a fact
that is an `Order` **and** is typed `:vip`. The index routes on `:vip`, and the alpha
applies the module. A plain `%Order{id: id}` does not constrain the shape, because there
`Order` is the type and the index has already applied it. That is also what lets a derived
type reach it.

You can only write `%Order{__type__: :vip, ...}` when `Order` declares a `__type__` field.
Elixir rejects an unknown struct key at compile time, so a struct without the field gives
a `KeyError` before this engine sees the pattern. Use a tagged map, or add the field.

Only the **outermost** `__type__` declares. A fact has one type, so a `__type__` nested
inside a field is ordinary data, and a pattern matches it like any other key.
`{:order, %{__type__: :billing, city: c}}` is an `:order` whose second element is matched
against a map with those two keys.

A type is **any term except `nil`**. `"express"`, `42` and `{:tenant, 7}` are all types,
and `derive/2` relates them like any other type. The index stores the type as a map key,
so it does not need to be an atom.

`nil` is the one exception. It means that a fact declares no type. This is what lets an
unset struct field fall back to the module, so `%MyApp.Order{}` is still a
`MyApp.Order` even on a struct that declares `__type__`. A plain `%{__type__: nil}` has no
module to fall back to, so it raises.

A *condition* is stricter than a fact here: `nil` written in a pattern always raises,
whatever the shape. `{nil, id}`, `%{__type__: nil}` and `%Order{__type__: nil}` all give
the same error. There is no reason to write it, and an unset field on a fact is not the
same as `nil` typed out by hand. Omit `__type__` to type a struct pattern by its module.

Every other value raises when inserted. A fact with an unexpected type would match
nothing, and it would do so silently. You could not tell that case apart from a rule that
does not apply. Pass `:fact_type_fn` to `Rete.Session.new/2` if your facts use some other
typing scheme.

Facts form a **multiset**. Inserting the same fact twice needs two retractions to remove
it. The second insert queues nothing, because the matches it would make already exist.

## Left hand side elements

| form | meaning |
|---|---|
| `{:order, cid, amt}` | fact pattern, any arity |
| `{:tick}` | a fact pattern that binds nothing |
| `%Order{id: id}` | struct fact pattern; the type is the module |
| `%{__type__: :order, id: id}` | tagged map fact pattern |
| `%Order{__type__: :vip, id: id}` | two constraints: an `Order`, **and** a `:vip` |
| `o = {:order, cid}` | bind the whole fact to `o` |
| `{:order, amt} when amt > 10` | per-condition guard |
| `o = {:order, amt} when amt > 10` | both |
| `[{:order, cid}]` | collect every matching fact (anonymous) |
| `orders = [{:order, cid}]` | collect every matching fact, bound to `orders` |
| `[{:order, cid, amt} when amt > 10]` | guarded collection |
| `{:not, [{:order, cid}]}` | a gate — `:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor` |
| `%{salience: 100}` **first** | the options map, not a condition |
| `) when <guard> do` | a rule-level guard over every binding |
| no conditions at all | fires once, on the first `fire_rules/2` — see below |

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

### A production with no conditions

A rule may declare no conditions at all. Write `defrule startup()`, or omit the
parentheses.

```elixir
defrule startup do
  {:started, :once}
end
```

Such a rule is true of the empty session. It fires on the first `fire_rules/2`, with
nothing inserted. It never fires again, however much you insert afterward.

Its conclusion rests on the root token instead of on a fact. So retracting everything you
inserted leaves the conclusion in place. This is the one conclusion
`Rete.Session.retract/2` cannot reach. `Rete.Inspect.explain/2` reports one activation for
the rule, with no matches behind it.

Salience applies as usual. So a rule with no conditions can run before the rest of the
ruleset, and seed a fact the other rules match on.

A query with no conditions answers exactly one row, which its body computes:

```elixir
defquery constant(), do: :constant

MyRuleset.constant(Rete.Session.new([MyRuleset]))   #=> []
MyRuleset.constant(session)                         #=> [:constant]
```

Fire first, as for any other query. The row then never changes. The root token is the full
match, and no fact can add to it or remove from it. The query binds nothing, so it can take
no parameters. A call that gives one raises an error. Read it as a `SELECT` with no `FROM`.

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

### What a collection costs

Gathering is cheap. A member is prepended, so a change costs the engine one cons cell, and
the list the body receives is the one the engine already holds. Reducing that list to a
number in the right hand side, as above, is the shape the engine is built for.

What the rest costs depends on **how members arrive**, not on how many there are. A
collection re-emits its group once per change, and every member that arrives before one
`fire_rules/2` is one change. So the rule fires once per fire, not once per member. Over
4,000 members:

| members per fire | body reduces the list | body concludes the list |
|---|---|---|
| 1 | 27 ms | 408 ms |
| 10 | 4.6 ms | 43 ms |
| 100 | 3.0 ms | 6.8 ms |
| all 4,000 | 3.4 ms | 3.3 ms |

So **fire once per batch**, and let the members arrive however they arrive. Both columns
fall with the batch, and by 100 a member at a time neither costs anything worth naming.

The batch is a batch of *inserts between fires*, not a batch inside one `insert/2` call.
Feeding 4,000 members one call at a time and firing once reaches the last row, the same as
one call carrying all 4,000. Only a `fire_rules/2` between them puts you back on the first.
So a caller that genuinely gets one event per call has nothing to restructure: collect the
events, fire when you want an answer. Before 0.5.0 each call propagated on its own, and the
first row was the only thing that shape could reach. `mix bench` contrasts the three under
"1,000 collection members, one per call, fired every call and fired once".

Where you cannot defer the fire, **conclude what you computed, not what you gathered.**
`{:spend, name, orders}` concludes a fact that grows with the group. The engine hashes all
of that fact on every change. That is the 408 ms against 27 ms above.

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

This is a real warning, not a formality. A collection gathers in **reverse arrival order**.
The same facts in a different order thus produce a different list. A member that you retract
and insert again comes back at the front. A rule that reduces its collection to something
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
stable. Do not expect it to return. It cost a pass over the group on every member
change, which is quadratic over the lifetime of the group. It paid that cost to support the
one kind of rule that this section tells you not to write. A sort in the right hand side
costs a pass each time the rule *fires*. Only the rules that need it pay, and only when they
need it.

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
MyApp.Adjustment`. So does any other term: `derive "express", "shipment"` and
`derive {:tenant, 7}, {:tenant, :any}` are ordinary derivations.

A derivation names types, never shapes. `derive MyApp.Refund, :adjustment` is therefore
allowed, and a `%MyApp.Refund{}` then reaches a condition written as
`%{__type__: :adjustment, id: id}`. An alpha pattern checks only the fields it names, not
the shape. If the parent's pattern names a field that the child does not have, the fact
does not match. This is not an error.

## Options: salience and meta

A `%{...}` literal in **first** position is the rule's options, not a condition. There is
one exception: a `__type__` key makes it a tagged-map condition instead. A map fact
pattern in that position that omits `__type__` is refused, and the error says so.

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
raises an error. Any other key raises an error too, except `:meta`, below.

### Attaching your own data: `:meta`

`:meta` is not read by the engine. It exists so you can attach your own data to a rule or
a query, for your own tooling to read back:

```elixir
defrule urgent(%{meta: %{owner: "billing", ticket: "OPS-42"}}, {:alarm, id}) do
  {:page, id}
end
```

The engine never validates or interprets its value. Read it back with
`Rete.get_rule_data/1`, which returns the escaped `Rete.IR.Production` of every rule and
query:

```elixir
iex> Rete.get_rule_data([MyRuleset]) |> Enum.map(&{&1.name, Keyword.get(&1.opts, :meta)})
[urgent: %{owner: "billing", ticket: "OPS-42"}]
```

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
`large_orders/1`, so you run it by calling it:

```elixir
MyRuleset.large_orders(session)  #=> [{1, 250}, {1, 900}, {2, 30}]
MyRuleset.summary(session)       #=> [%{customer: "Ada", count: 2}]

session |> MyRuleset.large_orders()  # a plain function, so it pipes
```

A query written in this way takes no parameters. It answers with every match that it
holds.

### The head

To read a query *by* a value, give the query a **head**. A head is a second argument list,
before the conditions. **It is the argument list of the function that the query becomes.**

```elixir
defquery orders_for(cid)({:large_order, cid, amt}) do
  {cid, amt}
end

defquery one_order(cid, amt)({:large_order, cid, amt}) do
  {cid, amt}
end
```

```elixir
MyRuleset.orders_for(session, 1)       #=> [{1, 250}, {1, 900}]
MyRuleset.orders_for(session, 2)       #=> [{2, 30}]
MyRuleset.one_order(session, 1, 250)   #=> [{1, 250}]
```

A head of N patterns gives `name/(N+1)`. The session is the first argument, so a query
pipes. A head is **not** a list of names. Every entry is an ordinary Elixir pattern, and a
call matches it. So you choose the shape that a caller writes:

```elixir
defquery by_pair(cid, tid)(...)             #=> by_pair(session, 1, 2)
defquery by_tuple({cid, tid})(...)          #=> by_tuple(session, {1, 2})
defquery by_map(%{cid: cid, tid: tid})(...) #=> by_map(session, %{cid: 1, tid: 2})
defquery by_list(cid: cid, tid: tid)(...)   #=> by_list(session, cid: 1, tid: 2)
```

The variables a head binds are what the engine **keys** the matches on. A read is thus a
map lookup, and not a scan. It costs what it returns, and not what the query holds. Four
heads over one set of conditions key the same way, and answer the same rows. They differ
only in what the caller writes.

The head is a pattern, so it behaves like one. A keyword head matches in the order that
you declared. A map head accepts a call that carries more keys. A repeated variable means
that the two values have to be equal, and it contributes one key:

```elixir
MyRuleset.by_list(session, tid: 2, cid: 1)
#=> ** (FunctionClauseError) no function clause matching in MyRuleset.by_list/2

defquery same(cid, cid)({:rec, cid, tid}), do: tid
MyRuleset.same(session, 1, 1)  #=> the matches keyed on %{cid: 1}
MyRuleset.same(session, 1, 2)  #=> ** (FunctionClauseError)
```

A call that does not match raises `FunctionClauseError`. A call of the wrong arity warns at
compile time, and the warning names the arity the query has. It raises
`UndefinedFunctionError` when it runs. Each is reported at the line that you wrote, and an
editor completes the call, because the query is an ordinary function.

A head may bind nothing. `defquery ping(:tick)(...)` keys on nothing and answers with
every match. The argument is then an assertion at the call site, and nothing more.

A `_`-prefixed name in a head behaves as it does in any `def`. It labels a position that
the query accepts and ignores, and it keys nothing:

```elixir
defquery rows({_cid, tid})({:rec, cid, tid, amt}), do: {cid, tid, amt}

MyRuleset.rows(session, {1, 5})  # keyed on tid alone, so `1` is a label and not a key
```

Rename it to `cid` to key on it. A guard cannot read it, because the pattern discards it.

A head pattern cannot carry a **default**, although an argument of any `def` may. A default
applies at the call site, and `Rete.Session.query/3` never reaches that call site. It takes
the bindings, so it could not honour the default, and one query would then read two ways.
Write a second query for the common value, or a wrapper function that supplies it.

A query has one head. Thus two ways to read the same conditions are two queries. Together
they cost one network: the engine matches the conditions above them one time, whether you
write one query or four.

Every variable a head binds must be a variable that the left hand side binds. **Every**
match must also carry it. The engine rejects a variable that only some branches of a
disjunction bind, because you could never name the matches from the other branches. A rule
cannot take a head.

A parameter matches by **term equality**, in the same way as a map key. `1` and `1.0` are
different parameter values, but `==` reports that they are equal.

### A guard on the head

A head pattern may carry a guard:

```elixir
defquery big_sales(cid, amt when amt > 1000)({:sale, cid, amt}) do
  {cid, amt}
end
```

```elixir
MyRuleset.big_sales(session, 1, 5_000)  #=> [{1, 5000}]
MyRuleset.big_sales(session, 1, 5)      #=> []
```

The guard becomes a **test on the left hand side**, so the query holds no match that fails
it, and a call naming a rejected value finds nothing. `[]` is the true answer, and it is
what `big_sales(session, 99, 5_000)` gets for a customer that does not exist.

Two things follow from the guard being a test and not a clause guard. It may be any
expression a rule body may call, and not only a valid Elixir guard:

```elixir
defquery named(name when String.length(name) > 3)({:user, name, id}), do: {name, id}
```

And it runs **when a match propagates, not when you call**. The guard runs one time for
each match, during `fire_rules/2`, and a call reads the store that recorded the answer. So
write a head guard as a function of its arguments. One that reads the clock fixes its
answer at the time of the match. `docs/design/ir.md` §2 has the argument for why the store
is the only place the guard can act.

A head guard reads only what the head binds. Every head variable is in scope for it,
whichever pattern you wrote it after. So `(cid, tid when cid < tid)` compares the two, and
two guards both apply:

```elixir
defquery ordered(cid, tid when cid < tid)(...)
defquery checked(cid when is_integer(cid), tid when tid > 0)(...)
```

Each pattern takes **one** `when`. Join the conditions with `and`, as you would in any
guard. A `def` head accepts more than one `when`, and a head pattern does not. The error
counts what you wrote and names the guard to write in its place:

```elixir
defquery ok(amt when amt > 1 and amt < 5)(...)   # one guard, two conditions

defquery no(amt when amt > 1 when amt < 5)(...)
#=> ** (ArgumentError) no writes 2 guards where one `when` is all that a head pattern
#     takes. Elixir nests each `when` after the first inside the one before it. A guard
#     here becomes a compiled function, and `when` is not an expression, so the nested
#     ones would reach it as a call. Join them with `and`:
#     `when amt > 1 and amt < 5`.
```

A chain of any length reports the same way, so four `when`s report four guards. This holds
wherever you write a guard. A condition, a collection and the rule level guard each take
one `when`, because each compiles a guard the same way.

Write a guard over the **other** bindings as a rule level guard instead, after the
conditions:

```elixir
defquery rows(cid when amt > 1)({:rec, cid, amt}), do: {cid, amt}
#=> ** (ArgumentError) the head guard of rows reads [:amt], which the head does not
#     bind. A head guard constrains the call, so it reads only what its own patterns
#     bind, which is [:cid]. To filter the matches instead, write a rule level guard:
#     `defquery rows(cid)(...) when amt > 1`.
```

The two can be written together. The head guard filters on what the head binds, and the
rule level guard filters on the rest:

```elixir
defquery rows(cid when cid > 0)({:rec, cid, amt}) when amt > 1, do: {cid, amt}
```

### Two rulesets may use the same query name

A query is identified by **module and name together**, never by the name alone. Because of
this, two rulesets that each define a `:summary` compose into one session without
collision. `MyRuleset.summary(session)` is unambiguous by construction, since it is an
ordinary function call. A typo here warns at compile time, and it is never an empty result
at runtime.

When the query is not known until it runs, name it with the pair:

```elixir
Rete.Session.query(session, {MyRuleset, :orders_for}, cid: 1)

for q <- [:large_orders, :summary], do: Rete.Session.query(session, {MyRuleset, q})
```

That is the whole addressing scheme: **call the query, or name it with `{module,
name}`.** A bare `:large_orders` is rejected. The error points at both forms. The same
`{module, name}` pair also names a rule for `Rete.Inspect.why_not/2`.

`Rete.Session.query/3` takes the **bindings**, and not the head. It is dispatched by
`{module, name}` while the program runs, so it cannot know the head pattern. For a head of
`({cid, tid})`, the function takes `{1, 2}` and this call takes `%{cid: 1, tid: 2}`. It
keeps the check that the generated function no longer needs: a partial key, an extra key
or an unknown key raises an error, and it does not answer `[]`.

```elixir
MyRuleset.by_tuple(session, {1, 2})
Rete.Session.query(session, {MyRuleset, :by_tuple}, cid: 1, tid: 2)   # the same rows

Rete.Session.query(session, {MyRuleset, :by_tuple}, cid: 1)
#=> ** (ArgumentError) the query MyRuleset.by_tuple takes parameters [:cid, :tid], and
#     was given [:cid]. The engine keys its matches on its parameters, so a call must
#     name every one of them, and no other name.
```

This engine uses the Clara model of query parameters. You declare the parameters first,
and they key the memory of the query node. A read is thus a hash lookup. This engine
differs in two ways: where you write the parameters, and how you address a query.

1. The parameters are the head of the declaration, `orders_for(cid)(...)`. The head is a
   list of patterns, so the parameters are the variables themselves, and not a separate
   list of names. The compiler checks each one against the bindings of the left hand side.
   It reports an error at the line that you wrote.
2. The `defquery` of Clara binds a variable that you give to `query`. The module system of
   Elixir already gives each query a module and a name. Here the query *is* the function,
   and the head is its argument list.

Two more points:

* a parameter keys on the **bindings**, before the body runs. It thus names a variable, and
  not a part of the result. You can read by a value that the body never returns.
* a query reads propagated state, so it answers **as of the most recent fire**. On a
  session you never fired that is `[]`. On one you fired and then inserted into, it is the
  answer from before that insert. See "Expecting anything to happen before `fire_rules/2`"
  below.

Row order is unspecified. Rows come back in the order the facts arrived in, so the same
facts fed in a different order answer in a different order. **Sort the result yourself if
order matters to you.**

The *set* of rows never varies, and one feed always answers the same way.

### What a parameter costs

A parameter keys the matches of a query. A keyed store holds one bucket for each distinct
value. The cost of a head is thus the **cardinality** of the variable that it names. The
head itself costs almost nothing.

These measurements insert 4,000 matches. `mix bench` runs them.

| head | insert | memory | buckets |
|---|---|---|---|
| no parameters | 2.3 ms | 1,108 KB | 1 |
| one parameter, 4 distinct values | 2.6 ms | 1,109 KB | 4 |
| one parameter, all distinct | 4.2 ms | 1,872 KB | 4,000 |
| three parameters, all distinct | 4.6 ms | 2,060 KB | 4,000 |

A parameter with a low cardinality costs very little. The added work is one `Map.take/2`
for each token, and the buckets hold the same tokens in a different arrangement. A
parameter on a unique field uses approximately 69% more memory, because each bucket has its
own structure, and there is now one bucket for each row. Retraction does not vary with the
head by more than the noise of the measurement.

### How much a parameter saves

A read still builds every row that it returns. The parameter saves only the scan. The
increase in speed thus follows the number of distinct values that the parameter takes.
These measurements read one value out of 4,000 matches. They compare a query with a head
against a query without a head, which Elixir code then filters:

| distinct values | rows returned | headless + filter | parameter | |
|---|---|---|---|---|
| 1 | 4,000 | 0.17 ms | 0.11 ms | 1.5× |
| 4 | 1,000 | 0.11 ms | 0.019 ms | 6× |
| 20 | 200 | 0.10 ms | 0.0022 ms | 45× |
| 200 | 20 | 0.090 ms | 0.00025 ms | 375× |
| 4,000 | 1 | 0.089 ms | 0.0001 ms | 860× |

Read the ratio, and not the two durations. Both of them move with the work that the body
does, and this body returns a value that it already holds. The table below shows what a
body that builds something does to the same comparison.

As a general rule, the increase in speed is approximately the number of distinct values.
The fixed cost of a call then becomes the limit. This rule applies if the values are
distributed equally. If one value holds most of the rows, that key gets the increase of
1×, and the other keys get more.

Therefore, name in the head the values that you read by. A parameter on a field with few
distinct values saves little and costs little. A parameter on a field with many distinct
values saves almost the full cost of the read. Do not add a parameter that you never
supply.

**A filter on the rows is the slow method.** It becomes slower as the body does more work.
A parameter keys on the bindings, so the body runs only for the rows that you asked for.
`Enum.filter/2` on the result runs the body for every match, and then discards most of the
rows. For a body that builds a map and a string, 50 reads select 1 row out of 4,000
matches. A filter on the result takes 18 ms. A parameter takes 0.01 ms. This is a factor of
approximately 1,600, against the 860× that the same selection gives with a body that builds
nothing. Declare the head if you know what you read by. Use a filter on the result only for
an occasional selection that the query does not support.

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
  leave two immortal facts behind. A rule with **no conditions** is the one exception: its
  support is the root token rather than a fact, so its conclusion stays.
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

Sharing works across modules too. Two rulesets you pass to `Rete.Session.new/2` together
match a condition they both write once per fact, not once each. The exception is a guard
that calls an **unqualified** function. Two modules can import a different `ok?/1` and
both write `when ok?(amt)`, and the name alone does not say which one is meant, so the
compiler keeps those apart. Qualify the call — `Checks.ok?(amt)` — to share it.

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

### Expecting anything to happen before `fire_rules/2`

```elixir
session =
  [MyRuleset] |> Rete.Session.new() |> Rete.Session.insert({:order, 1, 250})

Rete.Session.facts(session)  #=> just the order; no conclusions
MyRuleset.orders(session)    #=> [] — nothing has matched yet
```

`insert/2` and `retract/2` record facts and queue the work. **`fire_rules/2` is the only
call that matches anything.** It propagates everything waiting, runs the rules that match,
and returns once the session settles.

So a session you have not fired holds facts and nothing else. The engine has activated no
rule, and a query answers nothing. This is what lets you reason about a batch of facts
together, instead of each fact starting a cascade of its own.

The sharper case is the second insert, because the answer is stale rather than empty:

```elixir
settled = Rete.Session.fire_rules(session)
MyRuleset.orders(settled)      #=> [250]

queued = Rete.Session.insert(settled, {:order, 2, 900})
MyRuleset.orders(queued)       #=> [250] — the answer from before the insert
Rete.Session.settled?(queued)  #=> false

MyRuleset.orders(Rete.Session.fire_rules(queued))  #=> [250, 900]
```

**A query answers as of the most recent fire.** Fire before you query. A query cannot
raise here, because the last settled answer is a true answer about some state of the
session. `Rete.Session.settled?/1` reports whether a session has work waiting, for code
that did not do the insert itself.

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

If you wanted the rules scheduled separately, or told apart in `Rete.Inspect.explain/1`,
give them different names instead. That is what a name is for.

### Others worth knowing

| mistake | what you get |
|---|---|
| `defrule r({:order, cid})` with no `do` block | an error naming the rule; the body is the point of a rule |
| `{:order, _amt} when _amt > 0` | an error saying to rename it to `amt`; `_`-prefixed names are discarded |
| `[f = {:order, cid}]` | an error: bind the whole collection, not an element of it |
| `defquery q(%{params: [:cid]}, {:a, cid})` | an error: `params` is not a known option. Write it as the head instead: `defquery q(cid)({:a, cid})` |
| `defquery q(cid)(...)` then `q(session)` | a compile warning, then an `UndefinedFunctionError`: the head gives `q/2`, so `q/1` is undefined |
| `defquery q({:a, cid})` then `q(session, cid: 1)` | the same: `q` has no head, so it is `q/1` |
| `defquery q(cid: cid, tid: tid)(...)` then `q(session, tid: 2, cid: 1)` | a `FunctionClauseError`: a keyword head matches in the order you declared |
| `defquery q(cid when amt > 1)({:a, cid, amt})` | an error: a head guard reads only what the head binds. Write it after the conditions |
| `defquery q(cid when cid > 1 when cid < 5)({:a, cid})` | an error: one `when` is all a head pattern takes. Join them with `and`. A condition, a collection and a rule level guard are the same |
| `defquery q(cid \\ 1)({:a, cid})` | an error: a head pattern takes no default, because `Rete.Session.query/3` could not honour one |
| `defrule r({:order, cid \\ 1})` | an error: a condition matches a fact that is already there, so it has no call to default |
| `defrule r(cid)({:a, cid})` | an error: only a query is read, so only a query takes parameters |
| `@limit 5` … rule … `@limit 100` … same condition | an error: two conditions that read the same attribute at different values cannot share one compiled function |
