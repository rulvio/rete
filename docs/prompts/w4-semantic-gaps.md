# W4 — Semantic gaps in collection bindings

**Read [`_context.md`](_context.md) first.** It has the project briefing, the locked design
decisions, the file map and the testing lessons. Everything below assumes it.

**Status: Question 1 is resolved and implemented.** Questions 2 and 3 remain open, and
both are small. Do them before W5 and W6 if you are doing them at all, since they touch
documented behaviour.

---

## Why this phase exists

W1–W3 are complete and green: **526 tests**, clean build, the engine runs. Three questions were
left open because answering them means choosing semantics, and that is the user's call rather
than an implementation detail.

Question 1 has since been decided and implemented — it is recorded below so that it is not
reopened. Questions 2 and 3 are still open and are both small.

None of them is a crash. They are cases where a rule compiles, runs, and quietly means something
other than what its author intended — the worst failure mode a DSL can have.

---

## Question 1 — RESOLVED AND IMPLEMENTED

**A collection's pattern variable participates only if another condition's
*pattern* also matches on it — a real join. Otherwise it is inert: local to the
collection, constraining what is gathered, grouping nothing, binding nothing
downstream.**

Only a pattern counts. Not another condition's guard, not the collection's own
guard, not the rule level `when`, not the right hand side, and not a negation's
pattern (a negation binds nothing, so matching inside one is not a join).

Reading an inert variable outside its collection is a compile error naming the
variable and the collection.

Implemented in `Rete.DSL.Bindings.mark_inert/1` and `check_inert_reads!/1`, with
`:inert` on `Rete.IR.Coll`. Documented in the `Rete.IR.Coll` section of
`docs/design/w1-ir.md`. The headline fix:

```elixir
os = [{:order, cid, amt} when amt > lim]   #=> collects every order over lim
                                           #   (was: one singleton group per amount)
```

### The consequence worth knowing

`Rete.Compiler.Sort` defers collections, so a plain condition matching the
variable sorts *before* the collection and makes it an ordinary **join key**, not
a grouping variable. Grouping therefore arises in practice only between **two
collections**, where the sort defers both and the first groups by what the second
joins on.

Per-group firing for the classic `per_day` shape is consequently awkward. The
alternatives are a second collection, or collecting everything and using
`Enum.group_by/2` in the right hand side — which gives one fact holding a map
rather than one activation per group. An explicit grouping form was considered
and **deliberately deferred**; revisit only if it proves annoying in practice.

**Do not relitigate this.** If it needs changing, raise it with the user first.

---

## Question 2: collection element order is unspecified

The list a rule receives is in arrival order. That is deterministic under retract-and-reinsert
(verified), but nothing specifies it, so a rule doing `Enum.at(orders, 0)` or `hd(orders)` is
relying on something the engine does not promise.

Three options:

- **Leave it and document it as unspecified**, telling users to sort in the RHS. Honest, cheap,
  and the RHS has `Enum.sort_by` right there.
- **Specify arrival order** and test it. Users get a usable guarantee; the engine loses freedom
  to reorder later.
- **Sort by term order** before propagating. Fully deterministic regardless of arrival, at a
  per-change sort cost, and surprising for anyone expecting insertion order.

Whichever you pick, say so in `docs/design/w2-network.md` under the accumulate nodes, and add a
test that pins it. Right now the *behaviour* is deterministic but the *contract* is silent,
which is the worst of both.

---

## Question 3: `xor`/`xnor` semantics deserve a second look

`xor` is currently **exactly one**, and `xnor` its negation. Clara has no `xor`, so there was no
precedent; it was chosen when the gate set was implemented and is documented in
`docs/design/w1-ir.md`.

For n = 2 "exactly one" and "odd parity" agree. For n ≥ 3 they diverge: with three true
arguments, exactly-one says false, odd-parity says true. Worth one paragraph of thought and a
line in the docs confirming the choice is deliberate, since a user reaching for `xor` with three
arguments will have one of the two in mind and the other will surprise them.

There is a live consequence: a `xor` in first position expands to
`or(and(a, not b), and(not a, b))`, whose second branch begins with a negation. That used to make
`xor` silently degrade to "a and not b" — a bug found and fixed in W3 by seeding a root token.
There are tests for it; keep them.

---

## Definition of done

- Each of the three questions is either implemented or explicitly documented as a deliberate
  choice, with the reasoning recorded in the design docs.
- `mix test`, `mix compile --force --warnings-as-errors` and `mix format --check-formatted`
  all clean.
- Any semantics change has tests covering both the new behaviour and the shapes that must
  *not* change.
- `docs/design/w1-ir.md` and `docs/design/w2-network.md` describe what actually ships.
