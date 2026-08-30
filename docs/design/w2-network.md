# The compiled network

What the build phase produces and the engine runs. The companion to `w1-ir.md`,
which covers everything up to a classified `Rete.IR.Production`, and to
`w3-engine.md`, which covers what happens to a network once it exists.

Status: implemented, end to end.

---

## 1. Pipeline

The DSL front end runs at **compile** time, inside each `defrule`. What is left
for **build** time is the part that depends on the whole rule set rather than on
one rule:

```
Rete.Compiler.build([MyRuleset])
  |> Rete.Compiler.Negation.extract/1   rewrite compound negations into helpers
  |> Rete.Compiler.BetaGraph.build/1    beta nodes and edges, shared where equal
  |> Rete.Network.new/3                 alpha nodes grouped by code, taxonomy indexed
```

Node sharing is why this cannot happen per rule: whether two conditions collapse
onto one node depends on what every other rule already put in the graph.

---

## 2. Structure

```elixir
%Rete.Network{
  alphas:      %{code => %Node.Alpha{}},   # one per distinct expression code
  alpha_beta:  %{code => [beta_id]},       # the beta nodes each alpha feeds
  taxonomy:    %Rete.Taxonomy{},           # indexed: fact type => alpha codes
  graph:       %Rete.Compiler.BetaGraph{}, # beta nodes and their edges
  queries:     %{name => beta_id},
  productions: [%Rete.IR.Production{}]     # including generated helpers
}
```

The network is built once and never mutated, so any number of sessions can share
one. Working memory, the agenda and pending propagations are the engine's, not
the network's.

### How a fact travels

1. `Rete.Taxonomy.alpha_ids/2` maps the fact's type to alpha codes. **This is the
   only place the taxonomy is consulted.**
2. Each alpha's arity 1 function turns the fact into a bindings map, or `nil`.
   It matches a fact of *any* type on purpose — the type decision was step 1.
3. Matching elements go to the beta nodes in `alpha_beta`, and the engine
   propagates along the graph's forward edges.

---

## 3. Node kinds

Nodes are **data**; activation lives in `Rete.Engine.Nodes`. No node carries its
children: they are the graph's forward edges, because a node is shared precisely
when it is *equal*, and equality must not depend on how many rules happen to have
hung children off it.

| Node | Produced by | What the engine does with it |
|---|---|---|
| `Alpha` | any condition with a pattern | run `:fun` on a fact, `(fact) -> bindings \| nil` |
| `RootJoin` | first condition of a rule | turn each element straight into a token |
| `HashJoin` | later condition, no cross-condition guard | join tokens to elements on equality of `:join_bind` |
| `ExprJoin` | later condition with a cross-condition guard | hash join, then `:filter.(token_bindings, fact_bindings)` |
| `Negation` | `{:not, [one_condition]}` | propagate the token while **no** element matches on `:join_bind` |
| `NegationJoin` | negation with a cross-condition guard | as above, with the filter deciding what counts as a match |
| `Accumulate` | a collection binding | gather matching elements into a list under `:coll_binding` |
| `AccumulateJoin` | collection with a cross-condition guard | as above; candidates cannot be reduced until a token exists |
| `Test` | a rule level `when` | propagate the token when `:fun.(bindings)` is truthy |
| `Production` | a rule terminal | call `:rhs.(hash, bindings)`, logically insert the result |
| `Query` | a query terminal | hold the tokens that reached it, keyed for lookup |

### `:propagates_empty?` on the accumulate nodes

The locked empty-collection rule, precomputed. Note that `:new_bind` for a
collection counts only *participating* variables: one that no other condition's
pattern matches on is local to the collection and excluded, so a guarded
collection over otherwise-local variables is ungrouped and does propagate `[]`.
See the `Rete.IR.Coll` section of `w1-ir.md`.

* `true` when the pattern introduces **no** new variables. Every variable it uses
  is already fixed by the token, so there is exactly one group and the node
  propagates `[]` when nothing matches — the rule fires with an empty list.
* `false` when it introduces one. It groups by that variable, and a group only
  exists where a fact created it, so there is no empty group to invent.

### Collection element order is unspecified

**A rule may not depend on the order of the list it receives.** Sort in the right
hand side if order matters.

The engine does in fact keep collections in a deterministic order — elements are
inserted by term order rather than appended on arrival, so the same fact set
always produces the same list whatever order the facts arrived in, and a
retract-and-reinsert round trip restores it exactly. That is deliberate: without
it a rule that returns its collection would produce a different fact depending on
insertion order, and the engine's order-independence property would hold for
every rule except that one.

But it is an implementation guarantee, not a contract. Term order is arbitrary
from the author's point of view, and nothing about it is a useful thing to build
on.

---

## 4. Sharing

Two conditions collapse onto one node when they are **equal** and have the
**same parent set**. Equality alone is not enough, and the difference is a
correctness bug, not a missed optimisation:

```elixir
defrule a({:customer, cid}, {:order, cid, amt})
defrule b({:vendor, cid},   {:order, cid, amt})
```

The two `{:order, cid, amt}` conditions are equal but sit under different
parents. Sharing them would let a token from `{:vendor, ...}` join elements that
only ever belonged to `{:customer, ...}`, so `a` would fire on `b`'s facts.
Clara records the same requirement as issue 433.

Equality is `Rete.Network.Node.sharing_key/1`, built from **expression codes** —
never from captured functions, which are never equal, and never from a struct
holding `:__ast__`, which would compare quoted AST that is not part of identity.
W1 guarantees a code is deterministic across compilations and equal exactly when
behaviour is equal, which is what makes sharing reproducible between a full build
and an incremental one.

A terminal keys on its production's identity, so two rules with an identical left
hand side still get one terminal each and fire independently.

**Alpha sharing** is the same idea one level up: conditions are grouped by
expression code, so a condition written in four rules is matched once per fact.
`{:order, cid, _amt}` and `{:order, cid, _}` share, because W1 canonicalises
discarded variables.

---

## 5. Disjunctions

`{:or, [b1, b2]}` adds each branch as its own chain under the current parents and
hands the **union of the branch terminals** to the next condition. That is why a
condition is added under a *list* of parent ids: the condition after a
disjunction has one parent per branch, and the branches re-converge on it.

This is also why the left hand side is never flattened to DNF. Whole-LHS DNF is
exponential in the number of disjunctions; fanning out and re-converging per
condition is linear.

---

## 6. Compound negation extraction

A negation node watches one condition. It cannot watch a conjunction, and de
Morgan does not rescue it: `not(and(a, b)) = or(not a, not b)` is sound
propositionally, but rule conditions share existentially quantified variables, so
with orders `{1}` and refunds `{2}` the original is true and the rewrite is false.
`Rete.DSL.Normalize` therefore leaves a `CompoundNegation` for `Rete.Compiler.Negation`.

```elixir
defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]})

# becomes, in effect
defrule clean__neg_1({:customer, cid}, {:order, cid}, {:refund, cid}) do
  {:"...clean__neg_1", %{cid: cid}}        # the marker
end
defrule clean({:customer, cid}, {:not, [{:"...clean__neg_1", cid}]})
```

Three properties make this correct:

* **The marker is scoped.** It carries the ancestor bindings the conjunction
  joins on, and the negation matches on them. Otherwise one customer with both an
  order and a refund would suppress the rule for *every* customer — the negation
  would ask "does any match exist" instead of "does one exist for this `cid`".
  Clara's issue 304.
* **The helper repeats the prefix**, which is what binds those variables, and
  means the marker is only produced for groups that reached the negation.
* **The helper fires first**, via `:internal_salience`. Otherwise the negating
  rule observes an absence that had merely not been computed yet, fires, and is
  retracted by truth maintenance — a visible spurious activation.

The marker's *type* is the generated name, so the alpha index routes it to
exactly one place. Its alpha is the one exception to "an alpha matches a fact of
any type": it checks the tag, because a marker is engine machinery rather than a
user fact and a stray tuple of the same shape must not be mistaken for one.

Extraction runs after macro expansion, so a helper's expressions are plain
closures wrapped in `Rete.IR.Expr` rather than functions generated into a module.

---

## 7. What the engine must honour

* **Activation order** is `{salience, internal_salience}` descending, then node
  id. `Rete.Network.production_nodes/1` already returns them in that order.
  Ignoring `:internal_salience` breaks extracted negations.
* **Only logical inserts.** A production's `:rhs` returns facts to insert, truth
  maintained. There is no unconditional insert and no RHS retract. Session level
  retract exists, and TMS cascades from it.
* **Taxonomy is the index's job.** Never re-check a fact's type inside an alpha.
* **`:propagates_empty?`** decides whether an accumulate node emits `[]`.
* A `Test` node has no fact input, so it neither joins nor binds.

---

## 8. Known gaps

* **No subsumption between rules.** Two rules whose left hand sides differ only
  in a redundant condition build separate chains.
* **Sharing is prefix-only.** Two rules that share a *suffix* but not a prefix do
  not share anything, which is inherent to how a beta network is built.
