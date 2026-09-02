# The compiled network

This document covers what the build phase produces, and what the engine runs. It is the
companion to `ir.md`, which covers everything up to a classified `Rete.IR.Production`. It
is also the companion to `engine.md`, which covers what happens to a network once it
exists.

Status: implemented, end to end.

---

## 1. Pipeline

The DSL front end runs at **compile** time, inside each `defrule`. Build time handles the
part that depends on the whole rule set, not on one rule alone:

```
Rete.Compiler.build([MyRuleset])
  |> Rete.Compiler.Negation.extract/1   rewrite compound negations into helpers
  |> Rete.Compiler.BetaGraph.build/1    beta nodes and edges, shared where equal
  |> Rete.Network.new/3                 alpha nodes grouped by code, taxonomy indexed
```

Node sharing is why this cannot happen per rule. Whether two conditions collapse onto one
node depends on what every other rule already put in the graph.

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

The network is built once, and never mutated. Because of this, any number of sessions can
share one. Working memory, the agenda, and pending propagations belong to the engine, not
to the network.

### How a fact travels

1. `Rete.Taxonomy.alpha_ids/2` maps the fact's type to alpha codes. **This is the
   taxonomy's only use.**
2. Each alpha's arity-1 function turns the fact into a bindings map, or `nil`. It matches a
   fact of *any* type, on purpose — step 1 already decided the type.
3. Matching elements go to the beta nodes in `alpha_beta`. The engine propagates them along
   the graph's forward edges.

---

## 3. Node kinds

Nodes are **data**. Activation logic lives in `Rete.Engine.Nodes`. No node carries its own
children — the graph's forward edges hold that instead. A node is shared precisely when it
is *equal*, and equality must not depend on how many rules happen to hang children off it.

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

This node field precomputes the locked empty-collection rule.

`:new_bind` for a collection counts only *participating* variables. A variable that no
other condition's pattern matches on is local to the collection, and it is excluded. So a
guarded collection over otherwise-local variables is ungrouped, and it does propagate
`[]`. See the `Rete.IR.Coll` section of `ir.md`.

* `true` when the pattern introduces **no** new variables. Every variable it uses is
  already fixed by the token, so there is exactly one group. The node propagates `[]` when
  nothing matches, and the rule fires with an empty list.
* `false` when the pattern introduces one new variable. The node groups by that variable,
  and a group exists only where a fact created it. There is no empty group to invent.

### Collection element order is unspecified

**A rule may not depend on the order of the list it receives.** Sort the list in the right
hand side, if order matters to you.

The engine gathers in **reverse arrival order**: a member is prepended, and nothing is
sorted. So the same facts fed in a different order produce a different list, and a member
retracted and re-inserted comes back at the front rather than where it was.

The engine used to insert members in term order instead, so that a collection's order was
a function of its fact set. **That was a mistake**, and it was an expensive one. Finding an
arriving member's position meant walking the group, so every member change cost O(k) and
filling a collection was quadratic in its size. Prepending is O(1), and the new list shares
its whole tail with the old one.

The mistake was not the implementation, it was the promise. Nothing asked for it. The
contract has always said a rule may not depend on the gathered order, so the only rules the
sort could possibly help were the ones this page tells you not to write — and every other
rule in the session paid for them. `mix bench` puts the bill at 31 ms against 4 ms for
filling one collection of 1,000 members.

What was never in question: the *membership* of a collection is a function of its fact set.
Two feeds agree on what a collection holds, and a retract-and-reinsert round trip restores
it. Only the sequence moves, and the sequence was never promised.

---

## 4. Sharing

Two conditions collapse onto one node when they are **equal**, and they have the **same
parent set**. Equality alone is not enough. Getting this wrong is a correctness bug, not a
missed optimisation:

```elixir
defrule a({:customer, cid}, {:order, cid, amt})
defrule b({:vendor, cid},   {:order, cid, amt})
```

The two `{:order, cid, amt}` conditions are equal, but they sit under different parents.
Sharing them would let a token from `{:vendor, ...}` join elements that only ever belonged
to `{:customer, ...}`. Rule `a` would then fire on rule `b`'s facts. Clara records the same
requirement as issue 433.

`Rete.Network.Node.sharing_key/1` defines equality, built from **expression codes**. It
never uses captured functions, since two functions are never equal to each other. It never
uses a struct holding `:__ast__` either, since that would compare quoted AST, which is not
part of identity.

Invariant W1 guarantees that a code is deterministic across compilations, and that two
codes are equal exactly when the underlying behaviour is equal. This is what makes sharing
reproducible, between a full build and an incremental one.

A terminal keys on its production's identity. So two rules with an identical left hand
side still get one terminal each, and each fires independently.

**Alpha sharing** is the same idea, one level up. The compiler groups conditions by
expression code, so a condition written in four rules is matched once per fact.
`{:order, cid, _amt}` and `{:order, cid, _}` share a node, because W1 canonicalises
discarded variables.

---

## 5. Disjunctions

`{:or, [b1, b2]}` adds each branch as its own chain, under the current parents. It hands
the **union of the branch terminals** to the next condition. That is why the compiler adds
a condition under a *list* of parent ids: the condition after a disjunction has one parent
per branch, and the branches re-converge on it.

This is also why the compiler never flattens the left hand side to DNF. Whole-left-hand-side
DNF costs work exponential in the number of disjunctions. Fanning out and re-converging
per condition costs only linear work.

---

## 6. Compound negation extraction

A negation node watches one condition. It cannot watch a conjunction. De Morgan's law does
not rescue it here: `not(and(a, b)) = or(not a, not b)` is sound as propositional logic,
but rule conditions share existentially quantified variables. With orders `{1}` and
refunds `{2}`, the original is true and the rewrite is false.

Because of this, `Rete.DSL.Normalize` leaves a `CompoundNegation` for
`Rete.Compiler.Negation` to handle.

```elixir
defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]})

# becomes, in effect
defrule clean__neg_1({:customer, cid}, {:order, cid}, {:refund, cid}) do
  {:"...clean__neg_1", %{cid: cid}}        # the marker
end
defrule clean({:customer, cid}, {:not, [{:"...clean__neg_1", cid}]})
```

Three properties make this correct:

* **The marker is scoped.** It carries the ancestor bindings the conjunction joins on, and
  the negation matches on those bindings. Otherwise, one customer with both an order and a
  refund would suppress the rule for *every* customer — the negation would ask "does any
  match exist" instead of "does one exist for this `cid`". This is Clara's issue 304.
* **The helper repeats the prefix.** The prefix is what binds those bindings, so the
  marker is produced only for groups that reached the negation.
* **The helper fires first**, via `:internal_salience`. Otherwise, the negating rule would
  observe an absence that was merely not computed yet. It would fire, then get retracted
  by truth maintenance — a visible, spurious activation.

The marker's *type* is the generated name, so the alpha index routes it to exactly one
place. Its alpha is the one exception to "an alpha matches a fact of any type": it checks
the tag instead. A marker is engine machinery, not a user fact, so a stray tuple of the
same shape must never be mistaken for one.

Extraction runs after macro expansion. So a helper's expressions are plain closures
wrapped in `Rete.IR.Expr`, not functions generated into a module.

---

## 7. What the engine must honour

* **Activation order** is `{salience, internal_salience}` descending, then node id.
  `Rete.Network.production_nodes/1` already returns nodes in that order. Ignoring
  `:internal_salience` breaks extracted negations.
* **Only logical inserts.** A production's `:rhs` returns facts to insert, and the engine
  truth-maintains them. There is no unconditional insert, and no RHS retract.
  Session-level retract exists, and TMS cascades from it.
* **Taxonomy is the index's job.** Never re-check a fact's type inside an alpha.
* **`:propagates_empty?`** decides whether an accumulate node emits `[]`.
* A `Test` node has no fact input. So it neither joins nor binds.

---

## 8. Known gaps

* **No subsumption between rules.** Two rules whose left hand sides differ only in a
  redundant condition build separate chains.
* **Sharing is prefix-only.** Two rules that share a *suffix*, but not a prefix, share
  nothing. This limit is inherent to how a beta network is built.
