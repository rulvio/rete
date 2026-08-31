# The IR and the DSL front end

Status: implemented, end to end.

Modules:

| module | file | phase |
|---|---|---|
| `Rete.IR` | `lib/rete/ir.ex` | the shared data |
| `Rete.DSL.Parser` | `lib/rete/dsl/parser.ex` | W1, quoted AST → IR |
| `Rete.DSL.Normalize` | `lib/rete/dsl/normalize.ex` | W2a, gate normalization |
| `Rete.DSL.Bindings` | `lib/rete/dsl/bindings.ex` | W2b, binding classification and guard splitting |
| `Rete.DSL.Codegen` | `lib/rete/dsl/codegen.ex` | W3, expression construction and code generation |
| `Rete.Ruleset` | `lib/rete/ruleset.ex` | the macros that drive all of it |

This document is the contract between the compile phases, and between the front end and
the network builder, which is `docs/design/network.md`.

---

## 1. Pipeline

```
quoted DSL
  |> Rete.DSL.Parser.parse_production/4   # W1  AST -> IR, gates are placeholders
  |> Rete.DSL.Normalize.normalize_lhs/1   # W2a gates -> conditions, (compound) negations, {:or, ...}
  |> Rete.DSL.Bindings.classify/2         # W2b join_bind / new_bind / join_filter
  |> Rete.IR.lhs_bindings/1               # W2c recompute the production's :bind
  |> Rete.DSL.Codegen.compile/1           # W3  emit functions, escape into the module
  |> Rete.Compiler.build/2                # build time, see network.md
```

The first three steps take a `%Rete.IR.Production{}`, and return a
`%Rete.IR.Production{}`. All of this happens inside the `defrule`/`defquery` macro
expansion, so a phase may freely read and rewrite quoted AST. `Rete.IR.escape/1` is the
boundary — `Codegen.compile/1` calls it. After that boundary, only plain runtime data and
captured functions survive.

`Rete.Ruleset.build/4` runs the first four steps, and it is public. So a test can inspect
the classified IR of a declaration, without compiling a module for it.
`Rete.Ruleset.defrule/2` is then a two-liner:

```elixir
env |> Rete.Ruleset.build(decl, body, type) |> Rete.DSL.Codegen.compile()
```

A production written without a `do` block matches `defrule/1` instead, and this raises an
error naming the rule. There is nothing sensible to generate here. The RHS would become a
bodiless function head, and the module would fail to compile with "implementation not
provided for predefined def" — an error pointing at the generated function, not at the
rule.

`Codegen.compile/1` expands to

```elixir
quote do
  unquote_splicing(expr_defs(production))          # def __<code>__(args)
  @rule_data @rule_data ++ [unquote(IR.escape(production))]
  unquote(rhs_def(production))                     # def <name>(hash, bindings)
end
```

The order matters here. The escaped production captures the expression functions by name,
so the compiler must define them first.

**Ordering constraint.** `Bindings.classify/2` raises on a `Rete.IR.Gate`, on purpose. A
gate's arguments do not all bind, and silently mis-classifying one would produce wrong
join keys. Normalization must therefore run first.

`Bindings.classify/2` also raises once `:__ast__` has been dropped. So it must run before
`Codegen.compile/1`. Both checks are idempotent.

### What a ruleset module ends up containing

* `__<code>__/1` and `__<code>__/2` - one function per distinct expression,
* `<query_name>/1,2` - one per query, running it against a session,
* `__rhs_<name>__/2` - the RHS of each production,
* `get_rule_data/0`, `get_expr_data/0`, `get_taxo_data/0`, `get_version/0`.

`get_expr_data/0` returns `{code, fun}` for **every** expression reachable from the LHS:
alpha expressions, join filters, and tests alike, deduplicated by code.
`Rete.get_expr_data/1` merges this data across modules, again deduplicating by code.

---

## 2. Struct reference

### `Rete.IR.Production`

| field | type | set by | meaning |
|---|---|---|---|
| `:name` | `atom` | W1 | rule name; also the name of the generated RHS function |
| `:type` | `:rule \| :query` | W1 | |
| `:hash` | `integer` | W1 | `:erlang.phash2([decl_ast, body_ast])` after module-attribute qualification |
| `:opts` | `keyword` | W1 | from the leading options map, e.g. `[salience: 100]`; `[]` if absent |
| `:bind` | `[atom]`, **sorted** | W2c | every variable the LHS can make visible to the RHS, including fact/collection bindings; see below |
| `:lhs` | `t:Rete.IR.lhs/0` | W1, rewritten by W2 | ordered condition list |
| `:rhs` | `(hash, bindings_map -> facts) \| nil` | `escape/1` | `nil` before escaping |
| `:module` | `module` | W1 | defining module |
| `:__ast__` | `%{bind: %{atom => quoted}, decl: quoted, body: quoted}` | W1, narrowed by W2c | compile-time only, dropped by `escape/1` |

#### `:bind` is a product of the pipeline

`:bind` is **not** a pre-pass over the declaration. The parser cannot compute it. At that
point, every variable of every element looks like a binding. A variable that only occurs
inside a negation, or inside one branch of a disjunction, or only in a rule-level guard,
would all get swept up. The generated RHS head would then demand keys no token carries —
so the production could never fire.

`Rete.Ruleset.build/4` therefore recomputes it after classification, with

```elixir
{guaranteed, optional} = Rete.IR.lhs_bindings(production.lhs)
bind = Enum.sort(guaranteed ++ optional)
```

It then narrows `__ast__.bind` to the same key set. The two halves are:

* **guaranteed** — bound on every path through the LHS, so the key is in every token.
  `Rete.IR.bound_vars/1` accumulates this for each element. For a disjunction, only the
  *intersection* of its branches counts.
* **optional** — bound on some branch of a disjunction, but not on all of them. This is
  the union of the branches, minus the intersection.

`Rete.DSL.Codegen.rhs_def/1` reads the two differently:

```elixir
defrule either({:or, [{:user, id}, {:admin, level}]}) do {:seen, id, level} end
#=> def either(hash, %{} = bindings) do
#     id    = Map.get(bindings, :id)
#     level = Map.get(bindings, :level)
#     {:seen, id, level}
#   end
```

A guaranteed binding is destructured in the function head, `%{cid: cid}`. A token missing
it raises a `FunctionClauseError`, instead of firing the rule with a hole in it. An
optional binding is read with `Map.get/2` instead, and it is `nil` on the branches that do
not bind it — the same answer Clara's `compile-action` gives, since it `let`s every
binding key out of the token map.

Either way, the compiler binds only the variables the body actually reads. So a rule that
ignores a join variable still compiles under `--warnings-as-errors`.

A variable in *neither* half — one that only exists inside a negation, or is only read by
a rule-level guard — is not in `:bind` at all. A body that mentions it fails to compile,
with `undefined variable`. That is the intended answer: a negation binds nothing
downstream, so there is nothing to hand the RHS.

### `Rete.IR.Fact`

| field | type | set by | meaning |
|---|---|---|---|
| `:type` | `atom \| module` | W1 | declared fact type, see §4 |
| `:fact_binding` | `atom \| nil` | W1 | the `f` in `f = {:order, id}`; **not** in `:bind` |
| `:bind` | `[atom]`, **sorted** | W1 | variables bound by the pattern itself |
| `:alpha` | `%Expr{arity: 1, kind: :alpha}` | W1, rebuilt by W2b | `(fact) -> bindings_map \| nil` |
| `:join_filter` | `%Expr{arity: 2, kind: :join_filter} \| nil` | W2b | `(token_bindings, fact_bindings) -> boolean` |
| `:join_bind` | `[atom] \| nil` | W2b | variables shared with upstream conditions (hash-join keys) |
| `:new_bind` | `[atom] \| nil` | W2b | variables first introduced here |
| `:__ast__` | see §3 | W1 | compile-time only |

`join_bind ++ new_bind == bind` always holds, and both are sorted, because `:bind` is
sorted too. The fact binding is in neither: it is not a hash-join key.

Note that the variables a join filter reads from the token side are **not** in
`:join_bind`. `:join_bind` holds only the equality keys the engine indexes on.

### `Rete.IR.Coll`

Same as `Fact`, with `:coll_binding` instead of `:fact_binding`. This is the variable the
collected **list** binds to — `nil` for an anonymous `[{:order, id}]`.

`:alpha` has the same per-fact shape as a `Fact` alpha. The engine applies it to each
candidate element, never to the whole list.

#### `:inert` — collection-local variables

Elixir fuses binding and constraining. Writing `amt` in a pattern binds it — where Clara
would have written `(> amount ?lim)` and bound nothing. Taken literally, this makes a
guarded collection impossible to write:

```elixir
os = [{:order, cid, amt} when amt > lim]
```

`amt` is a new variable, and a collection that introduces a new variable groups by it. So
this would gather one singleton group per distinct amount, instead of every order over the
limit.

The rule that resolves this: **a collection's pattern variable participates only if
another condition also matches on it — a real join. Otherwise it is inert.**

Inert means local to the collection. The variable constrains which facts are gathered. It
groups nothing, and it binds nothing downstream. It stays in `:bind`, because the alpha
must still return it, for a join filter to test against. But it is excluded from
`:new_bind`, and from `Rete.IR.bound_vars/1`.

Only another condition's **pattern** counts:

| mentions the variable | counts as a join? |
|---|---|
| another condition's pattern | **yes** |
| another collection's pattern | **yes** |
| another condition's guard | no |
| the collection's own guard | no |
| the rule level `when` | no |
| the right hand side | no |
| a negation's pattern | no — a negation binds nothing, so it is not a join |

Reading an inert variable outside its collection is a compile error, naming the variable
and the collection. Every gathered fact has its own value, so there is no single value to
bind.

Note the interaction with `Rete.Compiler.Sort`, which defers collections. A plain
condition that matches the variable therefore sorts *before* the collection. This makes
the variable an ordinary **join key**, not a grouping variable. So in practice, grouping
arises only between **two collections**: the sort defers both, and the first groups by
what the second joins on.

To recover per-group firing, you have two options. Add a second collection that matches on
the variable. Or collect everything, and use `Enum.group_by/2` in the right hand side —
the same answer this engine already gives for `min`, `max`, and `sum`.

This deliberately differs from Clara, where an accumulator's source condition binds
whatever it names. Making the two the same would mean reintroducing explicit binding
syntax, and giving up what Elixir pattern matching buys.

#### Order

The order of the list a rule receives is **unspecified**. Sort it in the right hand side,
if order matters. The engine keeps collections in a deterministic order, so that order
independence holds, even for a rule that returns its collection. But this is an
implementation guarantee, not a contract. See `docs/design/network.md`.

#### Empty-collection semantics, decided by `:new_bind`

* no new variable: the condition propagates `[]`, and the rule fires with zero matches.
* at least one new variable: the condition groups by those variables, so only non-empty
  groups exist.

Because an inert variable is not in `:new_bind`, a guarded collection over otherwise-local
variables propagates `[]` like any other ungrouped collection.

### `Rete.IR.Test`

| field | type | set by | meaning |
|---|---|---|---|
| `:bind` | `[atom]`, sorted | W1 | variables the guard reads |
| `:expr` | `%Expr{arity: 1, kind: :test}` | W1 | `(bindings_map) -> boolean` |
| `:__ast__` | `%{guard: quoted, bind: %{atom => quoted}}` | W1 | compile-time only |

A rule-level guard (`defrule r(...) when <guard> do`) produces this. W1 appends it as the
**last** LHS element. It stays last, but not necessarily at the top level. When the
branches of a disjunction bind different variables, W2b absorbs everything downstream into
them, so the test ends up as the last element of every branch.

A `Test` has no fact input, so it binds nothing downstream. Its `:bind` field is what its
guard **reads**, and `Rete.IR.bound_vars/1` of a `Test` is always `[]`. So a variable the
test reads never enters the production's `:bind` on account of the test.

Everything a test reads has to come out of the token. So W2b
(`Rete.DSL.Bindings.check_test_vars!/2`) **rejects at compile time** a guard that reads a
variable no condition binds on its path — a typo, a variable that only exists inside a
negation, or one that only some branches of a disjunction bind. Left alone, such a guard
would compile into a function whose argument pattern demands a key no token carries. It
would fall through to `false`, and the rule would silently never fire. Because this check
runs per path, it catches this case:

```elixir
defrule r({:or, [{:gold, id, tier}, {:silver, id}]}) when tier > 1
#=> ** (ArgumentError) the rule level guard `tier > 1` reads `tier`, which no
#   condition binds on this path through the left hand side.
```

`tier > 1` cannot be evaluated on the silver branch at all. Write it where it can run
instead: as a per-condition guard, inside the branch that binds it.
`{:or, [{:gold, id, tier} when tier > 1, {:silver, id}]}` works. A rule-level guard over a
variable *every* branch binds is fine, since that variable is then guaranteed.

### `Rete.IR.Gate` (W1 placeholder)

| field | type | meaning |
|---|---|---|
| `:gate` | `:and \| :or \| :not \| :nand \| :nor \| :xor \| :xnor` | |
| `:args` | `[condition]` | parsed arguments, may nest further gates |
| `:code` | nested list `[gate \| arg_codes]` | structural id, e.g. `[:or, :fact_user_bind_id_expr_1, [:not, :fact_order_bind_id_expr_2]]` |

The parser recognises gates, and parses their arguments. It performs **no** normalization.
`Rete.DSL.Normalize` replaces every `Gate` with plain conditions, `Negation` and
`CompoundNegation` nodes, and `{:or, [[condition, ...], ...]}` disjunctions. So a `Gate`
never survives into a compiled module.

Semantics: n-ary `:xor` means *exactly one* argument holds. `:xnor` is its negation.
`:not` with several arguments negates their conjunction. See the `Rete.DSL.Normalize`
moduledoc for the degenerate-arity table — a 0-argument `and` is *true*, a 0-argument `or`
is *false*, and so on.

**Why "exactly one" rather than odd parity.** For two arguments, the two readings agree,
and Clara has no `xor` to inherit a convention from. They diverge from three arguments up:
with all three true, exactly-one says false, and odd-parity says true.

"Exactly one" matches how the word is used about rule conditions — "exactly one of these
applies". Odd parity is a circuit-design notion instead, one no rule author is likely to
reach for. This choice is deliberate. A rule that needs parity should say so with nested
two-argument `xor`s.

Normalization rewrites a negation by exactly three rules:

| written | becomes | why |
|---|---|---|
| `not(leaf)` | `Negation` | the ordinary case |
| `not(or(a, b))` | `and(not a, not b)` | de Morgan is sound over a disjunction |
| `not(and(a, b))` | `CompoundNegation` | de Morgan is **not** sound over a conjunction |

plus `not(not(x)) = x`, which collapses through a `CompoundNegation` as well.

### `Rete.IR.Negation`

`%Negation{condition: Fact.t() | Coll.t()}`. Normalization creates this. `:condition` is
always a single condition. A negation of a *conjunction* becomes a
`Rete.IR.CompoundNegation` instead. A negation of a *disjunction* turns into a conjunction
of negations, by De Morgan's law, and never survives as a `Negation`.

A negation never matches a fact, so the variables inside it are **not** bound for the
conditions that follow. Its inner condition is still classified, though, because the
engine needs the join keys to know which tokens the negation applies to.

### `Rete.IR.CompoundNegation`

`%CompoundNegation{conditions: [condition]}` means "no match satisfies all of these at
once". Normalization creates this for `{:not, [a, b]}`, `{:nand, [a, b]}`, and everything
else that desugars to a negated conjunction. `:conditions` is a conjunction, in author
order, with at least two elements. Each element is a `Fact`, `Coll`, `Test`, `Negation`,
or a nested `CompoundNegation` — never a `Gate`, and never an `{:or, ...}`.

**Why it exists.** `not(and(a, b)) = or(not a, not b)` is valid as propositional logic. It
becomes invalid the moment the conjuncts share an existentially quantified variable —
which is the normal case in a rules engine:

```elixir
defrule clean({:nand, [{:order, x}, {:refund, x}]}) do {:clean} end
```

This reads "no `x` has both an order and a refund". Applying De Morgan's law would make it
read "there are no orders at all, or there are no refunds at all" instead. With one order
for `x = 1` and one refund for `x = 2`, the intended reading is true, and the De Morgan
reading is false — the rule would do the opposite of what it says. So normalization
**never** applies De Morgan's law across a conjunction.

Like a `Negation`, it binds nothing downstream — `bound_vars/1` returns `[]`. But its inner
conditions *do* bind each other. `Bindings.classify/2` classifies them as a little LHS of
their own, starting from the outer bound set. So `refund` above gets `join_bind: [:x]`.

**What the compiler does with it.** `Rete.Compiler.Negation.extract/1` does exactly what
Clara's `get-complex-negation` does (`compiler.clj:971`, called from `add-production` at
line 1261 — that is, *before* `to-dnf`, which is why Clara's own de-Morgan-over-`and`
branch is unreachable).

It generates a helper production whose LHS is `:conditions`. That helper's RHS inserts a
marker fact, carrying the variables the negation joins on. The compiler then replaces the
`CompoundNegation` with a plain `Negation` of that marker. Nothing else in the pipeline can
evaluate a `CompoundNegation`, and nothing else tries.

### `Rete.IR.Expr`

| field | type | meaning |
|---|---|---|
| `:code` | `atom` | stable, human-readable unique id, see §5 |
| `:name` | `atom` | the generated function, always `:"__<code>__"` |
| `:arity` | `1 \| 2` | |
| `:kind` | `:alpha \| :test \| :join_filter` | fixes the calling convention |
| `:fun` | captured function \| `nil` | `nil` until `escape/1` |
| `:__ast__` | `%{args: quoted, body: quoted}` | compile-time only |

Calling conventions:

| kind | arity | signature | falsy result |
|---|---|---|---|
| `:alpha` | 1 | `(fact) -> bindings_map \| nil` | `nil` on a pattern mismatch or a failed guard |
| `:test` | 1 | `(bindings_map) -> boolean` | `false` |
| `:join_filter` | 2 | `(token_bindings, fact_bindings) -> boolean` | `false` |

`Codegen.expr_def/1` dispatches on `:kind` to pick that falsy result. An alpha must answer
`nil`, because `%{}` is a legitimate success value, for a pattern that binds nothing
(`{:tick}`).

For arity 2, `:__ast__.args` is a **two-element list**: `[token_pattern, fact_pattern]`.
`Codegen.expr_def/1` wraps them in `case {left, right} do`, and falls back to `false`.

### `:lhs` shape

```elixir
@type element :: condition() | {:or, [[element()]]}
@type lhs :: [element()]
```

The LHS is **never** flattened to DNF, since that explodes combinatorially. Normalization
runs per condition instead, as in Clara's `add-production`. An element is either one
condition, or a disjunction of conjunctions that fans out from the current parents and
re-converges before the next element.

The element type is **recursive**. A branch is itself a list of elements, and it may hold
a further `{:or, ...}`. Normalization never produces that nesting, but binding
classification does — when it absorbs the elements that follow a disjunction into branches
that classify them differently (see §2, `Rete.IR.Production`, and the `Rete.DSL.Bindings`
moduledoc). `Rete.IR.exprs/1`, `Rete.IR.escape/1`, and `Rete.IR.lhs_bindings/1` all recurse
through this structure.

Two edge values the network builder has to handle, both produced by degenerate gates:

* `{:or, [[]]}` is *true*: one branch that adds no condition. `normalize_lhs/1` splices it
  away, so it never reaches the builder through the normal path.
* `{:or, []}` is *false*: **no** branch at all, so the production can never fire. The
  compiler keeps it, because dropping it would change the production's meaning. Do not
  assume a disjunction has at least one branch.

An empty branch **never** appears next to a non-empty one. `{:or, [[], [a]]}` would mean
"match unconditionally, or match `a`" — which is just "match unconditionally", since the
empty branch is *true*, and `true or x` is `true`. Nothing is lost by collapsing it,
because only the variables bound by every branch survive a disjunction, and an empty
branch binds none.

`Normalize.simplify/1` therefore absorbs such a disjunction into `{:or, [[]]}`.
`normalize_lhs/1` then splices that away, so the element disappears from the LHS entirely.
The builder only ever sees `{:or, []}`, or a disjunction whose every branch has at least
one condition.

Across a disjunction, only the variables bound by *every* branch are bound afterwards —
the intersection, not the union. A union would hand a downstream condition a join key that
one branch never produces.

### The branch limit

Distribution is the one step that can explode. A conjunction of `k` disjunctions of `m`
branches each yields `m^k` branches, and every branch becomes a separate join path in the
beta network. `Normalize.to_dnf/1` refuses to build more than `Normalize.max_branches/0`
(256) branches for a single gate. It raises an `ArgumentError` instead, naming the gate,
its arity, and the branch count.

Negation is not a source of growth. `not` of a DNF of `n` branches is exactly one branch of
`n` literals — each a `CompoundNegation`, or a plain `Negation` when the branch is one
literal wide. So `not`, `nand`, `nor`, and `xnor` are all linear. `xor` is linear too:
every non-chosen argument of each "exactly one" branch gets negated, and each negation
contributes only a single branch.

---

## 3. `:__ast__` - what the later phases get to work with

`Fact` and `Coll`:

```elixir
%{
  pattern: quoted,   # the pattern as written, WITHOUT the binding and WITHOUT the `when`
  guard:   quoted | nil,
  bind:    %{atom => quoted_var},   # the variable AST for every entry of :bind
  source:  quoted    # the whole element as written, for error messages
}
```

`Test`: `%{guard: quoted, bind: %{atom => quoted_var}}`.
`Production`: `%{bind: %{atom => quoted_var}, decl: quoted, body: quoted}`.
`Expr`: `%{args: quoted, body: quoted}`.

Two ordering rules that must not be confused:

* the `:bind` **list** on a struct is sorted. It is a set, so you may compare it freely.
* the `:bind` **map** keeps `Map.keys/1` order instead. This order is spliced into
  generated code, and it is part of the expression hash. Do not re-order it, or rebuild it
  from a sorted list — doing so changes expression codes, and node sharing silently
  degrades.

`escape/1` drops `:__ast__`, so nothing downstream of the macro can see quoted AST. After
classification, `__ast__.guard` on a condition holds only the **alpha** part of the guard.
The lifted part is recoverable at `join_filter.__ast__.body`.

### Rebuilding expressions

`Rete.DSL.Bindings` rebuilds an alpha through the public helpers rather than editing the
struct:

```elixir
{type, args} = Parser.compile_pattern(env, fact.__ast__.pattern)
alpha = Parser.build_alpha_expr(type, fact.__ast__.pattern, args, alpha_guard, fact.__ast__.bind)
```

`build_alpha_expr/5` (a delegate to `Codegen.alpha_expr/5`) hashes `{pattern, body}`. So a
condition whose guard was fully lifted out produces exactly the same code as if it had
been written without a guard at all. This is the point: it lets the condition share the
alpha node. A test checks this.

---

## 4. Fact types and the "alpha matches any type" rule

`:type` is the **declared** type. The alpha expression never checks it. The alpha index
applies type filtering instead — including taxonomy (`derive`/`underive`) — when it
decides whether to propagate a fact to a node. This is asserted on purpose, in
`test/rete_test.exs` ("bind7 tests that the fact matches any fact type"), in
`test/rete/dsl/parser_test.exs`, and in `test/rete/dsl/codegen_test.exs`.

| written | `:type` | compiled alpha pattern |
|---|---|---|
| `{:tick}` | `:tick` | `{_}` |
| `{:order, id}` | `:order` | `{_, id}` |
| `{:order, id, amt}` | `:order` | `{_, id, amt}` |
| `%Order{id: id}` | `Order` (expanded module) | `%{id: id}` - the `__struct__` check is dropped |
| `%{__type__: :order, id: id}` | `:order` | `%{id: id}` - the `__type__` key is dropped |

Facts at runtime are therefore any-arity tagged tuples, structs (with the module as the
type), or tagged maps (`%{__type__: t}`).

---

## 5. Expression naming and hashing

`Rete.DSL.Codegen` owns this. `expr_code/3`, `expr_name/1`, `type_code/1`, and
`expr_hash/2` each have exactly one implementation, and both `Parser` and `Bindings` call
them.

```
fact_<type>_bind_<v1>_<v2>_..._expr_<hash>        alpha without guard
test_fact_<type>_bind_<v1>_..._expr_<hash>        alpha with guard
test_bind_<v1>_..._expr_<hash>                    test over bindings only
join_<type>_bind_<v1>_..._expr_<hash>             join filter
```

* `<type>` is the type atom. A module loses its `Elixir.` prefix, and `.` becomes `_`
  (`MyApp.Order` → `MyApp_Order`).
* `<v...>` are the variables the expression reads, **sorted**, joined with `_`. An empty
  bind set gives `fact_tick_bind_expr_<hash>`. For a join filter, these are the guard's
  variables from both sides — for example, `join_order_bind_amt_t_expr_<hash>` for
  `{:order, amt} when amt > t`.
* `<hash>` is `:erlang.phash2/1` of the meta-stripped, escaped, `term_to_binary`'d pair
  `{args_ast, body_ast}`. For an alpha, that pair is `{pattern_ast, body_ast}`. For a
  test, it is `{bindings_map_ast, guard_ast}`.
* the generated function is named `:"__<code>__"`.

Three rewrites make the hash see through things that are lexical in Elixir, but not in the
AST. `Parser.expand_aliases/2` and `Parser.resolve_constants/2` apply them, over the whole
declaration *and* body, before anything else runs:

* every alias and `__MODULE__` is resolved to the module it names. So `H.ok?(amt)` under
  `alias A, as: H`, and under `alias B, as: H`, do not hash the same.
* every `@x` becomes `{:@, _, [{:x, _, DefiningModule}]}`. So the same pattern in two
  modules does not share one expression.
* every `^v` is unwrapped to `v`. A condition compiles to a standalone function, which has
  no enclosing scope for a pin to refer to, so all three spellings used to fail to compile
  outright. `^@limit` and `^7` become the literal value. `^amt` becomes plain `amt`, which
  is already how this DSL spells a join, so ordinary classification turns it into a join
  key.

Only alias nodes are expanded, never macros — the body has to reach the generated function
exactly as the user wrote it. Pinned values and `@x` are never bindings.

### Determinism

`Codegen.ast_hash/1` normalises the AST before hashing it. Each normalisation exists so
that the hash is a function of what the code *means*:

* **metadata is stripped**, so a production keeps its hash when it moves to a different
  line.
* **discarded variables are canonicalised to `_`**. So `{:order, _x}` and `{:order, _y}` —
  byte-identical once compiled, since a `_`-prefixed name is never a binding — share one
  expression.
* **the bindings map is sorted**, wherever it is spliced into a hashed AST.
  `Map.to_list/1` on an atom-keyed map iterates in atom-table *interning* order. So the
  hash used to depend on what the VM happened to intern first: the same source produced
  different codes on a full build and on an incremental one, silently duplicating every
  alpha node on rebuild. Never reintroduce an unsorted map into a hashed AST.

### Module attribute values

An attribute's value is **not** part of its code, and it cannot be. `@limit` expands to a
hidden `Module.__get_attribute__` call, and that call only runs once the module body is
evaluated — after every macro in that body has already expanded. `Module.get_attribute/3`
still reports the default value at expansion time.

Hashing the name alone is what keeps two conditions that read the same attribute sharing
one node — the ordinary case. `Codegen.check_attr_values!/3` catches the dangerous case
instead: the same pattern on either side of a reassignment. The compiler emits this check
into the module body, where the values *are* readable. It records what each code saw, and
it raises when that code is reached again with a different value — instead of letting the
second rule silently reuse the first rule's compiled function.

### Sharing

Codes are the node-sharing key for W2. Two conditions with the same code have
byte-identical behaviour, and they must map to the same alpha node. Within a module,
`Codegen.expr_defs/1` guards each definition with `Module.defines?/2`. So the compiler
compiles a shared condition once, and both `Expr` structs capture the same function.
Across modules, `Rete.get_expr_data/1` deduplicates by code, and it keeps the first module
that defines each one. Never derive new codes from anything unstable: line numbers,
`make_ref`, or the map iteration order of a rebuilt map.

---

## 6. Accepted LHS element forms

| form | result |
|---|---|
| `{:type, a, b, ...}` (any arity, incl. `{:type}`) | `Fact` |
| `%Mod{f: v}` | `Fact`, `type: Mod` |
| `%{__type__: :type, f: v}` | `Fact`, `type: :type` |
| `f = <pattern>` | `Fact` with `fact_binding: :f` |
| `<pattern> when <guard>` | `Fact`, guard split between `:alpha` and `:join_filter` |
| `f = <pattern> when <guard>` | both |
| `[<pattern>]` | `Coll` with `coll_binding: nil` |
| `[<pattern> when <guard>]` | `Coll` with a guard |
| `c = [<pattern>]`, `c = [<pattern> when <guard>]` | `Coll` with `coll_binding: :c` |
| `{gate, [element, ...]}` | normalized into conditions, `Negation`s, `CompoundNegation`s and `{:or, ...}` |
| trailing `... ) when <guard> do` | `Test` appended last |

Parsing rules and disambiguations:

* the **leading** `%{...}` literal of a declaration is the options map. The exception: a
  `__type__` key makes it a tagged-map condition instead.
* `{gate, [...]}` is a gate whenever `gate` is one of the seven gate atoms, and the single
  argument is a list. So a two-element fact tuple named `:and`, with a list payload,
  cannot be expressed.
* `when` binds looser than `=`. So `f = {:t, x} when g` arrives as
  `{:when, _, [{:=, _, [f, pattern]}, g]}`, and the parser peels off both decorations
  before compiling the pattern.
* an inner and an outer guard on a collection combine with `and` (`[{:t, x} when a] when
  b` → `a and b`).
* variables named `_` or `_foo` are never bindings, in any position. Because they are
  discarded, a guard that reads one is a compile-time error, naming the variable to
  rename (see §7).
* the fact/collection binding is not in `:bind`, and the alpha does not return it — the
  engine adds it to the token instead. `Rete.IR.bound_vars/1` returns `:bind ++
  [binding]`, which is what makes a condition's binding visible downstream.

Compile-time errors (all `ArgumentError`):

* a map fact pattern with no `__type__`, or a non-literal-atom `__type__`.
* a struct pattern whose alias does not expand to a module.
* any other pattern shape ("unsupported condition ...").
* binding an element *inside* a collection (`[f = {:t, x}]`).
* binding or guarding a gate.
* binding a condition twice.
* a guard — per condition or rule level — reading a variable that is not available where
  it runs (see §7).
* a production with no `do` block.
* a `Gate`, or an already-escaped condition, reaching binding classification.

---

## 7. Guard splitting

The compiler splits a per-condition guard conjunct by conjunct, over its top-level
`and`/`&&` chain:

* a conjunct whose variables are all bound by the condition's **own** pattern — plus
  pinned values and module attributes, which are compile-time constants — stays in the
  arity-1 alpha. So the alpha rejects unmatched facts before any join work happens.
* any other conjunct becomes part of the arity-2 join filter.

```elixir
defrule r({:threshold, t}, {:order, amt} when amt > 0 and amt > t)
#                                                ^ alpha      ^ join filter
```

A guard that the compiler cannot decompose — an `or` mixing local and upstream variables,
or a single expression touching both — goes to the join filter **whole**. Correctness
beats early filtering here. `&&` counts as a splittable conjunction, alongside `and`.

In the join filter, each guard variable is destructured from the **fact** side, when the
condition's own pattern binds it, and from the **token** side otherwise. So a join
variable is never bound twice in the same pattern. The compiler wraps the body in
`if ..., do: true, else: false`, so the boolean contract holds, whatever the user wrote.

A guard variable that is neither local nor bound upstream produces a compile-time
`ArgumentError` (`Bindings.check_guard_vars!/3`), naming the variable and the condition.
Left uncaught, it would compile into a join filter that reads the token side for a key
that is never there. The production could then never fire.

A **forward reference** does *not* trigger this error. `Rete.Compiler.Sort` runs before
classification, and it reorders binders to the front. So
`defrule r({:order, amt} when amt > t, {:threshold, t})` is sorted into
`{:threshold, t}, {:order, amt} when amt > t`, and it becomes indistinguishable from the
same rule written that way round. What remains is:

* a **`_`-prefixed variable**, as in `{:order, _amt} when _amt > 0`. The pattern discards
  it, so it is in no bindings map, and in no token. The error tells you to rename it to
  `amt`. Inlining it into the alpha instead, where the argument pattern does bind it,
  would only trade this error for Elixir's own "the underscored variable is used after
  being set" warning — which is fatal under `--warnings-as-errors`.

That is why `Codegen.join_filter_expr/3` may keep deriving the guard's variables with
`Parser.parse_bind/1`, which drops `_`-prefixed names. A join filter can never contain
one.

`Bindings.check_test_vars!/2` checks the **rule-level** guard the same way, against the
variables bound on its path. It has no fact of its own, so everything it reads has to
already be in the token. See `Rete.IR.Test` in §2 for the disjunction case — the one place
the two checks differ in consequence, not in rule. A per-condition guard inside a branch
sees that branch's own bindings. A rule-level guard runs once per branch instead, so it
cannot read a variable that only some branches bind.

---

## 8. Known gaps

* **A local guard conjunct after a cross-condition one filters late.** Guard splitting
  takes the maximal *leading* run of local conjuncts, not every local conjunct. The alpha
  runs before the beta node, so hoisting a conjunct over one written earlier loses
  short-circuit protection: `amt > t and div(100, amt) > 1` raised `ArithmeticError` on
  `amt = 0`, when split by value alone. Recovering the lost early filtering needs a purity
  analysis of the conjunct being hoisted.
* **An unqualified local or imported call in a guard still hashes the same across
  modules.** `valid?(amt)` is byte-identical in two modules that define `valid?/1`
  differently. So both produce one code, and `Rete.get_expr_data/1` keeps only one of the
  two functions. The compiler resolves aliases and `__MODULE__`, but not bare local calls.
  Building a network stays safe: `Rete.Compiler` qualifies any code more than one module
  contributed as `<code>@<module>`, before building anything from it. So the collision
  costs sharing, not correctness. But `Rete.get_expr_data/1` itself still reports only one
  function.
* **Per-group firing is hard to reach.** A collection variable participates only when
  another condition's *pattern* matches on it, and `Rete.Compiler.Sort` defers
  collections. So a plain condition that matches the variable sorts before the collection,
  and it becomes an ordinary join key instead. In practice, grouping needs **two
  collections**. The alternative: collect everything, and use `Enum.group_by/2` in the
  right hand side, which yields one fact holding a map, instead of one activation per
  group. An explicit grouping form was considered, and deferred — see
  `Rete.DSL.Bindings.mark_inert/1`.
* **No subsumption in normalization.** `a ∨ (a∧b)` is not reduced to `a`, on purpose.
  Branches carry bindings, and dropping the longer branch would drop the bindings `b`
  introduces. Repeated literals and contradictory conjunctions *are* pruned, though, and a
  disjunction with an empty branch is absorbed into *true*.
* **Guard splitting and inertness use different notions of "own".** A guard may read the
  collection's inert variables — that is exactly what makes them inert. So a guard's
  scope is every variable the pattern binds, while `Rete.IR.bound_vars/1` reports only
  what escapes. Conflating the two makes a guarded collection fail to compile. See
  `own_scope/1` in `Rete.DSL.Bindings`.
