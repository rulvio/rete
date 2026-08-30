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

This document is the contract between the compile phases, and between the front
end and the network builder (W4), which has not been written yet.

---

## 1. Pipeline

```
quoted DSL
  |> Rete.DSL.Parser.parse_production/4   # W1  AST -> IR, gates are placeholders
  |> Rete.DSL.Normalize.normalize_lhs/1   # W2a gates -> conditions, (compound) negations, {:or, ...}
  |> Rete.DSL.Bindings.classify/2         # W2b join_bind / new_bind / join_filter
  |> Rete.IR.lhs_bindings/1               # W2c recompute the production's :bind
  |> Rete.DSL.Codegen.compile/1           # W3  emit functions, escape into the module
  |> W4: beta network construction
```

The first three steps take a `%Rete.IR.Production{}` and return a
`%Rete.IR.Production{}`. All of it happens inside the `defrule`/`defquery` macro
expansion, so a phase may freely read and rewrite quoted AST. `Rete.IR.escape/1`,
which `Codegen.compile/1` calls, is the boundary: after it only plain runtime
data and captured functions survive.

`Rete.Ruleset.build/4` is the first four steps and is public, so a test can
inspect the classified IR of a declaration without compiling a module for it.
`Rete.Ruleset.defrule/2` is then a two liner:

```elixir
env |> Rete.Ruleset.build(decl, body, type) |> Rete.DSL.Codegen.compile()
```

A production written without a `do` block matches `defrule/1` instead, which
raises naming the rule. There is nothing sensible to generate: the RHS would
become a bodiless function head and the module would fail to compile with
"implementation not provided for predefined def", pointing at the generated
function rather than at the rule.

`Codegen.compile/1` expands to

```elixir
quote do
  unquote_splicing(expr_defs(production))          # def __<code>__(args)
  @rule_data @rule_data ++ [unquote(IR.escape(production))]
  unquote(rhs_def(production))                     # def <name>(hash, bindings)
end
```

The order matters: the escaped production captures the expression functions by
name, so they have to be defined first.

**Ordering constraint.** `Bindings.classify/2` raises on a `Rete.IR.Gate`, on
purpose - a gate's arguments do not all bind, and mis-classifying one silently
would produce wrong join keys. Normalization must therefore run first.
`Bindings.classify/2` also raises once `:__ast__` has been dropped, so it must
run before `Codegen.compile/1`. Both are idempotent.

### What a ruleset module ends up containing

* `__<code>__/1` and `__<code>__/2` - one function per distinct expression,
* `<rule_name>/2` - the RHS of each production,
* `get_rule_data/0`, `get_expr_data/0`, `get_taxo_data/0`, `get_version/0`.

`get_expr_data/0` returns `{code, fun}` for **every** expression reachable from
the LHS: alpha expressions, join filters and tests alike, deduplicated by code.
`Rete.get_expr_data/1` merges that across modules, again deduplicating by code.

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

`:bind` is **not** a pre-pass over the declaration. The parser cannot compute
it: at that point every variable of every element looks like a binding, so a
variable that only occurs inside a negation, or inside one branch of a
disjunction, or only in a rule level guard, would all be swept up and the
generated RHS head would demand keys no token carries - which is to say the
production could never fire.

`Rete.Ruleset.build/4` therefore recomputes it after classification, with

```elixir
{guaranteed, optional} = Rete.IR.lhs_bindings(production.lhs)
bind = Enum.sort(guaranteed ++ optional)
```

and narrows `__ast__.bind` to the same key set. The two halves are:

* **guaranteed** - bound on every path through the LHS, so the key is in every
  token. `Rete.IR.bound_vars/1` of each element accumulates it, and only the
  *intersection* of the branches of a disjunction counts.
* **optional** - bound on some branch of a disjunction but not on all of them,
  i.e. the union minus the intersection.

`Rete.DSL.Codegen.rhs_def/1` reads the two differently:

```elixir
defrule either({:or, [{:user, id}, {:admin, level}]}) do {:seen, id, level} end
#=> def either(hash, %{} = bindings) do
#     id    = Map.get(bindings, :id)
#     level = Map.get(bindings, :level)
#     {:seen, id, level}
#   end
```

A guaranteed binding is destructured in the head, `%{cid: cid}`, so a token
missing it raises a `FunctionClauseError` rather than firing the rule with a
hole in it. An optional one is read with `Map.get/2` and is `nil` on the
branches that do not bind it - the same answer Clara's `compile-action` gives,
which `let`s every binding key out of the token map. Only the variables the
body actually reads are bound either way, so a rule that ignores a join
variable still compiles under `--warnings-as-errors`.

A variable that is in *neither* half - one that only exists inside a negation,
or is only read by a rule level guard - is not in `:bind` at all, so a body
that mentions it fails to compile with `undefined variable`. That is the
intended answer: a negation binds nothing downstream, and there is nothing to
hand the RHS.

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

`join_bind ++ new_bind == bind` always holds, and both are sorted because
`:bind` is. The fact binding is in neither: it is not a hash-join key. Note that
the variables a join filter reads from the token side are **not** in
`:join_bind`; `:join_bind` is only the equality keys the engine indexes on.

### `Rete.IR.Coll`

Same as `Fact`, with `:coll_binding` instead of `:fact_binding`: the variable the
collected **list** binds to, `nil` for an anonymous `[{:order, id}]`.

`:alpha` has the same per-fact shape as a `Fact` alpha - it is applied to each
candidate element, never to the list.

Empty-collection semantics, decided by `:new_bind`:

* no new variable → the condition propagates `[]` and the rule fires with zero
  matches;
* at least one new variable → group by those variables, so only non-empty groups
  exist.

### `Rete.IR.Test`

| field | type | set by | meaning |
|---|---|---|---|
| `:bind` | `[atom]`, sorted | W1 | variables the guard reads |
| `:expr` | `%Expr{arity: 1, kind: :test}` | W1 | `(bindings_map) -> boolean` |
| `:__ast__` | `%{guard: quoted, bind: %{atom => quoted}}` | W1 | compile-time only |

Produced by a rule-level guard (`defrule r(...) when <guard> do`), appended by
W1 as the **last** LHS element. It stays last, but not necessarily at the top
level: when the branches of a disjunction bind different variables W2b absorbs
everything downstream into them, and the test ends up as the last element of
every branch.

A `Test` has no fact input, so it binds nothing downstream: `:bind` is what its
guard **reads**, and `Rete.IR.bound_vars/1` of a `Test` is `[]`. A variable it
reads is therefore never in the production's `:bind` on account of the test.

Everything a test reads has to come out of the token, so W2b
(`Rete.DSL.Bindings.check_test_vars!/2`) **rejects at compile time** a guard
reading a variable that no condition binds on its path - a typo, a variable that
only exists inside a negation, or one that only some branches of a disjunction
bind. Left alone, such a guard compiles into a function whose argument pattern
demands a key no token carries; it falls through to `false` and the rule
silently never fires. Because the check is per path, this is an error:

```elixir
defrule r({:or, [{:gold, id, tier}, {:silver, id}]}) when tier > 1
#=> ** (ArgumentError) the rule level guard `tier > 1` reads `tier`, which no
#   condition binds on this path through the left hand side.
```

`tier > 1` cannot be evaluated on the silver branch at all. Write it where it
can be, as a per-condition guard inside the branch that binds it:
`{:or, [{:gold, id, tier} when tier > 1, {:silver, id}]}`. A rule level guard
over a variable *every* branch binds is fine, since it is then guaranteed.

### `Rete.IR.Gate` (W1 placeholder)

| field | type | meaning |
|---|---|---|
| `:gate` | `:and \| :or \| :not \| :nand \| :nor \| :xor \| :xnor` | |
| `:args` | `[condition]` | parsed arguments, may nest further gates |
| `:code` | nested list `[gate \| arg_codes]` | structural id, e.g. `[:or, :fact_user_bind_id_expr_1, [:not, :fact_order_bind_id_expr_2]]` |

The parser recognises gates and parses their arguments; it performs **no**
normalization. `Rete.DSL.Normalize` replaces every `Gate` with plain conditions,
`Negation` and `CompoundNegation` nodes and `{:or, [[condition, ...], ...]}`
disjunctions, so a `Gate` never survives into a compiled module.

Semantics: n-ary `:xor` means *exactly one* argument holds; `:xnor` is its
negation; `:not` with several arguments negates their conjunction. See the
`Rete.DSL.Normalize` moduledoc for the degenerate-arity table (a 0-argument
`and` is *true*, a 0-argument `or` is *false*, and so on).

Normalization rewrites a negation by exactly three rules:

| written | becomes | why |
|---|---|---|
| `not(leaf)` | `Negation` | the ordinary case |
| `not(or(a, b))` | `and(not a, not b)` | de Morgan is sound over a disjunction |
| `not(and(a, b))` | `CompoundNegation` | de Morgan is **not** sound over a conjunction |

plus `not(not(x)) = x`, which collapses through a `CompoundNegation` as well.

### `Rete.IR.Negation`

`%Negation{condition: Fact.t() | Coll.t()}`. Created by normalization,
`:condition` is always a single condition. A negation of a *conjunction* is a
`Rete.IR.CompoundNegation` instead; a negation of a *disjunction* is de Morganed
into a conjunction of negations and never survives.

A negation never matches a fact, so the variables inside it are **not** bound for
the conditions that follow. Its inner condition is still classified, because the
engine needs the join keys to know which tokens the negation applies to.

### `Rete.IR.CompoundNegation`

`%CompoundNegation{conditions: [condition]}` - "no match satisfies all of these
at once". Created by normalization for `{:not, [a, b]}`, `{:nand, [a, b]}` and
everything that desugars to a negated conjunction. `:conditions` is a
conjunction in author order, at least two elements, each of them a `Fact`,
`Coll`, `Test`, `Negation` or a nested `CompoundNegation` - never a `Gate`,
never an `{:or, ...}`.

**Why it exists.** `not(and(a, b)) = or(not a, not b)` is valid
propositionally and invalid the moment the conjuncts share an existentially
quantified variable, which is the normal case in a rules engine:

```elixir
defrule clean({:nand, [{:order, x}, {:refund, x}]}) do {:clean} end
```

reads "no `x` has both an order and a refund". De Morganed it would read "there
are no orders at all, or there are no refunds at all". With one order for
`x = 1` and one refund for `x = 2` the intended reading is true and the de
Morganed one is false - the rule does the opposite of what it says. So
normalization **never** applies de Morgan across a conjunction.

Like a `Negation` it binds nothing downstream (`bound_vars/1` returns `[]`). Its
inner conditions *do* bind each other: `Bindings.classify/2` classifies them as
a little LHS of their own, starting from the outer bound set, so the `refund`
above gets `join_bind: [:x]`.

**What W4 has to do with it.** Extract it, exactly as Clara's
`get-complex-negation` does (`compiler.clj:971`, called from `add-production`
at line 1261, i.e. *before* `to-dnf` - which is why Clara's own
de-Morgan-over-`and` branch is unreachable). Generate a helper production whose
LHS is `:conditions` and whose RHS inserts a marker fact carrying the variables
the negation joins on, then replace the `CompoundNegation` with a plain
`Negation` of that marker. Nothing else in the pipeline can evaluate one, and
nothing else should try.

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

`:kind` is what `Codegen.expr_def/1` dispatches on to pick that falsy result. An
alpha must answer `nil`, because `%{}` is a legitimate success value for a
pattern that binds nothing (`{:tick}`).

For arity 2, `:__ast__.args` is a **two-element list** `[token_pattern,
fact_pattern]`; `Codegen.expr_def/1` wraps them in `case {left, right} do` and
falls back to `false`.

### `:lhs` shape

```elixir
@type element :: condition() | {:or, [[element()]]}
@type lhs :: [element()]
```

The LHS is **never** flattened to DNF - that explodes combinatorially.
Normalization is per condition, as in Clara's `add-production`: an element is
either one condition or a disjunction of conjunctions that fans out from the
current parents and re-converges before the next element.

The element type is **recursive**: a branch is itself a list of elements and
may hold a further `{:or, ...}`. Normalization never produces that, but binding
classification does, when it absorbs the elements that follow a disjunction
into branches that classify them differently (see §2, `Rete.IR.Production`, and
the `Rete.DSL.Bindings` moduledoc). `Rete.IR.exprs/1`, `Rete.IR.escape/1` and
`Rete.IR.lhs_bindings/1` all recurse through it.

Two edge values W4 has to handle, both produced by degenerate gates:

* `{:or, [[]]}` is *true* - one branch adding no condition. `normalize_lhs/1`
  splices it away, so it should not reach W4 through the normal path.
* `{:or, []}` is *false* - **no** branch, the production can never fire. It is
  kept, because dropping it would change the meaning of the production. Do not
  assume a disjunction has at least one branch.

An empty branch **never** appears next to a non-empty one. `{:or, [[], [a]]}`
would mean "match unconditionally, or match `a`", which is just "match
unconditionally": the empty branch is *true* and `true or x` is `true`. Nothing
is lost by collapsing it, because only the variables bound by every branch
survive a disjunction and an empty branch binds none. `Normalize.simplify/1`
therefore absorbs such a disjunction to `{:or, [[]]}`, which `normalize_lhs/1`
then splices away, so the element disappears from the LHS entirely. W4 sees
either `{:or, []}` or a disjunction whose every branch has at least one
condition.

Across a disjunction, only the variables bound by *every* branch are bound
afterwards (the intersection). A union would hand a downstream condition a join
key that one branch never produces.

### The branch limit

Distribution is the one step that can explode: a conjunction of `k`
disjunctions of `m` branches each yields `m^k` branches, and every branch is a
separate join path in the beta network. `Normalize.to_dnf/1` refuses to build
more than `Normalize.max_branches/0` (1024) branches for a single gate and
raises an `ArgumentError` naming the gate, its arity and the branch count.

Negation is not a source of growth. `not` of a DNF of `n` branches is exactly
one branch of `n` literals, each a `CompoundNegation` (or a plain `Negation`,
when the branch is one literal wide), so `not`, `nand`, `nor` and `xnor` are all
linear. `xor` is linear too, because every non-chosen argument of each
"exactly one" branch is negated and therefore contributes a single branch.

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

* the `:bind` **list** on a struct is sorted - it is a set, compare it freely;
* the `:bind` **map** keeps `Map.keys/1` order, which is spliced into generated
  code and is part of the expression hash. Do not re-order or rebuild it from a
  sorted list, or expression codes change and node sharing silently degrades.

`:__ast__` is dropped by `escape/1`, so nothing downstream of the macro can see
quoted AST. After classification, `__ast__.guard` on a condition holds only the
**alpha** part of the guard; the lifted part is recoverable at
`join_filter.__ast__.body`.

### Rebuilding expressions

`Rete.DSL.Bindings` rebuilds an alpha through the public helpers rather than
editing the struct:

```elixir
{type, args} = Parser.compile_pattern(env, fact.__ast__.pattern)
alpha = Parser.build_alpha_expr(type, fact.__ast__.pattern, args, alpha_guard, fact.__ast__.bind)
```

`build_alpha_expr/5` (a delegate to `Codegen.alpha_expr/5`) hashes
`{pattern, body}`, so a condition whose guard was fully lifted out produces
exactly the same code as if it had been written without a guard - which is the
point: it shares the alpha node. There is a test for that.

---

## 4. Fact types and the "alpha matches any type" rule

`:type` is the **declared** type. The alpha expression never checks it: type
filtering, including taxonomy (`derive`/`underive`), is applied by the alpha
index when it decides whether to propagate a fact to a node. This is asserted on
purpose in `test/rete_test.exs` ("bind7 tests that the fact matches any fact
type"), in `test/rete/dsl/parser_test.exs` and in
`test/rete/dsl/codegen_test.exs`.

| written | `:type` | compiled alpha pattern |
|---|---|---|
| `{:tick}` | `:tick` | `{_}` |
| `{:order, id}` | `:order` | `{_, id}` |
| `{:order, id, amt}` | `:order` | `{_, id, amt}` |
| `%Order{id: id}` | `Order` (expanded module) | `%{id: id}` - the `__struct__` check is dropped |
| `%{__type__: :order, id: id}` | `:order` | `%{id: id}` - the `__type__` key is dropped |

Facts at runtime are therefore any-arity tagged tuples, structs (type = the
module) or tagged maps (`%{__type__: t}`).

---

## 5. Expression naming and hashing

Owned by `Rete.DSL.Codegen` - `expr_code/3`, `expr_name/1`, `type_code/1` and
`expr_hash/2` have exactly one implementation, which `Parser` and `Bindings`
both call.

```
fact_<type>_bind_<v1>_<v2>_..._expr_<hash>        alpha without guard
test_fact_<type>_bind_<v1>_..._expr_<hash>        alpha with guard
test_bind_<v1>_..._expr_<hash>                    test over bindings only
join_<type>_bind_<v1>_..._expr_<hash>             join filter
```

* `<type>` is the type atom; a module loses its `Elixir.` prefix and `.` becomes
  `_` (`MyApp.Order` → `MyApp_Order`).
* `<v...>` are the variables the expression reads, **sorted**, joined with `_`.
  An empty bind set gives `fact_tick_bind_expr_<hash>`. For a join filter these
  are the guard's variables from both sides, e.g.
  `join_order_bind_amt_t_expr_<hash>` for `{:order, amt} when amt > t`.
* `<hash>` is `:erlang.phash2/1` of the meta-stripped, escaped,
  `term_to_binary`'d pair `{args_ast, body_ast}` - for an alpha,
  `{pattern_ast, body_ast}`; for a test, `{bindings_map_ast, guard_ast}`.
* the generated function is `:"__<code>__"`.

Three rewrites make the hash see through things that are lexical in Elixir but
not in the AST. They happen in `Parser.expand_aliases/2` and
`Parser.resolve_constants/2`, over the whole declaration *and* body, before
anything else:

* every alias and `__MODULE__` is resolved to the module it names, so
  `H.ok?(amt)` under `alias A, as: H` and under `alias B, as: H` do not hash
  the same;
* every `@x` becomes `{:@, _, [{:x, _, DefiningModule}]}`, so the same pattern
  in two modules does not share one expression;
* every `^v` is unwrapped to `v`. A condition compiles to a standalone function,
  which has no enclosing scope for a pin to refer to, so all three spellings
  used to fail to compile outright. `^@limit` and `^7` become the literal;
  `^amt` becomes `amt`, which is already how this DSL spells a join, so the
  ordinary classification turns it into a join key.

Only alias nodes are expanded, never macros: the body has to reach the
generated function as the user wrote it. Pinned values and `@x` are never
bindings.

### Determinism

`Codegen.ast_hash/1` normalises before hashing, and each normalisation exists so
that the hash is a function of what the code *means*:

* **metadata is stripped**, so a production keeps its hash when it moves lines;
* **discarded variables are canonicalised to `_`**, so `{:order, _x}` and
  `{:order, _y}` — byte identical once compiled, since a `_`-prefixed name is
  never a binding — share one expression;
* **the bindings map is sorted** wherever it is spliced into a hashed AST.
  `Map.to_list/1` on an atom keyed map iterates in atom table *interning* order,
  so the hash used to depend on what the VM happened to intern first: the same
  source produced different codes on a full build and on an incremental one,
  silently duplicating every alpha node on rebuild. Never reintroduce an
  unsorted map into a hashed AST.

### Module attribute values

An attribute's value is **not** part of its code, and cannot be. `@limit`
expands to a `Module.__get_attribute__/4` call that only runs once the module
body is evaluated, which is after every macro in that body has expanded;
`Module.get_attribute/3` still reports the default at expansion time.

Hashing the name alone is what keeps two conditions reading the same attribute
sharing one node, which is the ordinary case. The dangerous case — the same
pattern either side of a reassignment — is caught instead by
`Codegen.check_attr_values!/3`, emitted into the module body where the values
*are* readable. It records what each code saw and raises when that code is
reached again with a different value, rather than letting the second rule
silently reuse the first one's compiled function.

### Sharing

Codes are the node-sharing key for W2: two conditions with the same code have
byte-identical behaviour and must map to the same alpha node. Within a module,
`Codegen.expr_defs/1` guards each definition with `Module.defines?/2`, so a
shared condition is compiled once and both `Expr` structs capture the same
function. Across modules, `Rete.get_expr_data/1` deduplicates by code and keeps
the first module that defines it. Do not derive new codes from anything
unstable (line numbers, `make_ref`, map iteration order of a rebuilt map).

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

* the **leading** `%{...}` literal of a declaration is the options map - unless
  it has a `__type__` key, which makes it a tagged-map condition instead;
* `{gate, [...]}` is a gate whenever `gate` is one of the seven gate atoms and
  the single argument is a list, so a two-element fact tuple named `:and` etc.
  with a list payload cannot be expressed;
* `when` binds looser than `=`, so `f = {:t, x} when g` arrives as
  `{:when, _, [{:=, _, [f, pattern]}, g]}` and both decorations are peeled off
  before the pattern is compiled;
* an inner and an outer guard on a collection are combined with `and`
  (`[{:t, x} when a] when b` → `a and b`);
* variables named `_` or `_foo` are never bindings, in any position - and
  because they are discarded, a guard that reads one is a compile-time error
  naming the variable to rename (see §7);
* the fact/collection binding is not in `:bind` and is not returned by the alpha
  - the engine adds it to the token. `Rete.IR.bound_vars/1` returns
  `:bind ++ [binding]`, which is what makes a condition's binding visible
  downstream.

Compile-time errors (all `ArgumentError`):

* a map fact pattern with no `__type__`, or a non-literal-atom `__type__`;
* a struct pattern whose alias does not expand to a module;
* any other pattern shape ("unsupported condition ...");
* binding an element *inside* a collection (`[f = {:t, x}]`);
* binding or guarding a gate;
* binding a condition twice;
* a guard - per condition or rule level - reading a variable that is not
  available where it runs (see §7);
* a production with no `do` block;
* a `Gate` or an already-escaped condition reaching binding classification.

---

## 7. Guard splitting

A per-condition guard is split conjunct by conjunct over its top-level
`and`/`&&` chain:

* a conjunct whose variables are all bound by the condition's **own** pattern
  (plus pinned values and module attributes, which are compile-time constants)
  stays in the arity 1 alpha, so unmatched facts are rejected before any join
  work happens;
* any other conjunct becomes part of the arity 2 join filter.

```elixir
defrule r({:threshold, t}, {:order, amt} when amt > 0 and amt > t)
#                                                ^ alpha      ^ join filter
```

A guard that is not decomposable - an `or` mixing local and upstream variables,
or a single expression touching both - goes to the join filter **whole**:
correctness beats early filtering. `&&` counts as a splittable conjunction
alongside `and`.

In the join filter, each guard variable is destructured from the **fact** side
when the condition's own pattern binds it and from the **token** side otherwise,
so a join variable is never bound twice in the same pattern. The body is wrapped
in `if ..., do: true, else: false`, so the boolean contract holds whatever the
user wrote.

A guard variable that is neither local nor bound upstream is a compile-time
`ArgumentError` (`Bindings.check_guard_vars!/3`), naming the variable and the
condition. Left alone it would compile into a join filter reading the token
side for a key that is never there, so the production could never fire. Two
shapes hit it:

* a **forward reference**, `defrule r({:order, amt} when amt > t, {:threshold, t})`.
  This is the single call site W2's topological condition sort has to relax
  once it reorders binders to the front.
* a **`_`-prefixed variable**, `{:order, _amt} when _amt > 0`. The pattern
  discards it, so it is in no bindings map and in no token; the error says to
  rename it to `amt`. Inlining it into the alpha instead - where the argument
  pattern does bind it - would only trade the error for Elixir's own "the
  underscored variable is used after being set" warning, which is fatal under
  `--warnings-as-errors`.

The second of those is why `Codegen.join_filter_expr/3` may keep deriving the
guard's variables with `Parser.parse_bind/1`, which drops `_`-prefixed names: a
join filter can never contain one.

The **rule level** guard is checked the same way by
`Bindings.check_test_vars!/2`, against the variables bound on its path - it has
no fact of its own, so everything it reads has to be in the token. See
`Rete.IR.Test` in §2 for the disjunction case, which is the one place the two
checks differ in consequence rather than in rule: a per-condition guard inside a
branch sees that branch's bindings, while a rule level guard is checked once per
branch and so cannot read a variable only some branches bind.

---

## 8. Known gaps

* **A local guard conjunct after a cross-condition one filters late.** Guard
  splitting takes the maximal *leading* run of local conjuncts, not every local
  conjunct, because the alpha runs before the beta node and hoisting a conjunct
  over one written before it loses short-circuit protection —
  `amt > t and div(100, amt) > 1` raised `ArithmeticError` on `amt = 0` when
  split by value. Recovering the lost early filtering needs a purity analysis of
  the conjunct being hoisted.
* **An unqualified local or imported call in a guard still collides across
  modules.** `valid?(amt)` is byte identical in two modules that define
  `valid?/1` differently, so both hash the same and `Rete.get_expr_data/1` keeps
  one. Aliases and `__MODULE__` are resolved; bare local calls are not.
* **A `CompoundNegation` is not executable yet.** W2a produces it and
  `Bindings.classify/2` classifies its inner conjunction, but nobody extracts it
  into a helper production, so W4 must do that before it can build a network for
  a rule that uses `not`/`nand` over more than one condition. See
  `Rete.IR.CompoundNegation`.
* **No subsumption in normalization.** `a ∨ (a∧b)` is not reduced to `a`, on
  purpose: branches carry bindings and dropping the longer branch would drop the
  bindings `b` introduces. Repeated literals and contradictory conjunctions
  *are* pruned, and a disjunction with an empty branch is absorbed to *true*.
* **Nothing about the network.** Firing, retraction, truth maintenance, taxonomy
  application and node construction are all W4.
