# W6 — Hardening, documentation, release

**Read [`_context.md`](_context.md) first.** It has the project briefing, the locked design
decisions, the file map and the testing lessons. Everything below assumes it.

**Prerequisites:** [W4](w4-semantic-gaps.md) and [W5](w5-observability.md). This phase writes
the public documentation and the behavioural suite, so the semantics must be settled and the
inspection API must exist before you describe them.

---

## Why this phase exists

The engine is correct as far as the tests reach, and the tests were written by the same person
who wrote the engine. This phase attacks it from outside: a suite derived from a mature engine's
behaviour, property tests that do not care what the implementation looks like, and the
documentation a first-time user actually needs.

---

## Part 1 — A behavioural suite mined from Clara

Clara has roughly **8,000 lines of behavioural tests** accumulated over a decade of real use.
They encode edge cases nobody thinks of up front, and they are the single highest-value input
available to this project.

```
clara-rules/src/test/clojure/clara/
  test_rules.clj              2556   the main suite
  test_accumulation.clj       1756   collections; most of it is accumulator-library
                                     specific and does NOT apply — mine the retraction
                                     and re-accumulation cases, skip min/max/sum
  test_truth_maintenance.clj   448   the highest-value file for this project
  test_bindings.clj            390   binding and join edge cases
  test_negation.clj            355   negation edges
  test_node_sharing.clj        270   sharing; mostly verified already in W2
  test_simple_rules.clj        195   good starting point, small and broad
  test_exists.clj              169   :exists — we have no equivalent, see below
  test_queries.clj              61
  test_infinite_loops.clj      363   loop detection
```

**Mine behaviours, not code.** For each test, ask "what does this assert about how a rules
engine behaves?" and write that as an idiomatic ExUnit test against this DSL. Do not translate
Clojure. Many tests will not apply at all:

- Anything about the accumulator library (`acc/min`, `acc/max`, `acc/sum`, `acc/distinct`) —
  we have collect-all only, by an explicit user decision.
- Anything about unconditional insert or RHS retract — we have logical inserts only.
- ClojureScript, Java interop, durability, session caching.
- `:exists` — Clara desugars it to an accumulator plus a test. Consider whether this DSL wants
  it. `{:not, [{:not, [x]}]}` is the double-negation spelling and should already work; a test
  confirming that is worth more than new syntax.

Expect to find real bugs. Budget for that rather than treating the suite as a formality.

A pass worth doing explicitly: **read `test_truth_maintenance.clj` in full.** TMS is where the
subtle bugs live in every rules engine, and this project has already found several
(self-justifying conclusions, support counting, cascade ordering).

---

## Part 2 — Property tests

Add `stream_data` to `mix.exs`. The invariants below are implementation-independent, and the
first two have already caught real bugs here.

**Generate**: a small universe of fact shapes over a fixed ruleset that uses joins, taxonomy,
negation, a collection, a compound negation and a disjunction — the existing `Everything`
fixture in `test/rete/engine_test.exs` is a reasonable base but extend it.

1. **Insert/retract symmetry.** Insert a random multiset, fire, then insert-and-retract any
   extra fact; the derived state must be identical before and after.
2. **Order independence.** The same multiset inserted in any order, and in any batch grouping
   (one at a time, in pairs, all at once, with `fire_rules` at different points), gives the same
   derived state.
3. **Full drain.** After retracting everything, `session.state.memory` must equal a fresh
   session's memory — `Rete.Session.new([Mod]).state.memory`. Use equality against a fresh
   session, not "everything is empty": that also pins the number of seeded root tokens, which an
   emptiness check structurally cannot see.
4. **Support counting.** A fact concluded by exactly one match has count 1; a fact with *n*
   independent supports needs *n* retractions. This is the invariant that catches
   over-propagation, which is otherwise invisible in `facts/1`.
5. **Equivalence to a rebuild.** After any sequence of inserts and retracts, the session's facts
   must equal those of a session built from scratch with the surviving multiset. This is the
   strongest property available and subsumes several of the others.

A random op-sequence fuzz (say 1,000 insert/retract ops, comparing against a rebuild after each
step) is worth more than any single property. One of the W3 reviewers ran exactly this and it
found nothing — which was genuinely reassuring, unlike a passing hand-written suite.

### Mutation testing

Then verify the suite can *fail*. Break the engine deliberately and check the tests notice.
A harness that worked well:

```bash
cp lib/rete/engine/nodes.ex /tmp/nodes.keep
cat > /tmp/mut.py <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert old in s, "anchor missing in " + p
open(p, "w").write(s.replace(old, new, 1))
PY
python3 /tmp/mut.py lib/rete/engine/nodes.ex '<old text>' '<new text>'
mix test 2>&1 | grep -E "^Result:"
cp /tmp/nodes.keep lib/rete/engine/nodes.ex
```

Mutations that proved informative, all in `lib/rete/engine/nodes.ex` unless noted:

| Mutation | What it breaks |
|---|---|
| `send_left(state, node, now -- before)` → `now` | collection re-sends unchanged groups |
| `retract_left(state, node, before -- now)` → `[]` | stale collection never retracted |
| `unmatched(...) -- unmatched(...)` → first term only | negation edge transitions |
| `matches?(%Node.ExprJoin{...})` → always `true` | join filter ignored |
| `negation_match?(%Node.NegationJoin{...})` → always `true` | negation filter ignored |
| `Memory.take_insertion(...)` → `{state.memory, []}` | truth maintenance |
| `insert_sorted(...)` → `pending ++ [activation]` (agenda.ex) | salience ordering |
| `{store, Enum.reverse(removed)}` → `{store, targets}` (memory.ex) | phantom retractions |

If a mutation survives, work out **why** before adding a test — some are semantically
equivalent and the analysis is the useful part. For example, "release all free tokens" versus
"release newly free tokens" are provably identical for a plain negation and differ only for a
`NegationJoin` with two tokens under one join key that disagree about an element. That analysis
produced the sharpest test in the current suite.

Aim for every mutation either caught or explained. Record the surviving-but-equivalent ones in
the design docs so the next person does not re-derive them.

---

## Part 3 — Documentation

### README

Currently the `mix new` placeholder — "**TODO: Add description**". It is the first thing anyone
sees. It needs:

- What this is, in two sentences, and who it is for.
- A complete worked example: ruleset, session, insert, fire, query, retract, and the output at
  each step. The demo in `test/rete/engine_test.exs` is a good basis.
- Installation from Hex.
- A short "how a Rete engine thinks" section — facts in, rules match, conclusions are
  truth-maintained — because most Elixir developers have not used one and the mental model is
  the barrier, not the API.
- Honest limitations: no accumulator library, logical inserts only, no async firing, no
  durability, and the state of performance work (untuned, correctness first).
- Attribution to Clara as the semantic reference, and to `taxo` for hierarchies.

### A DSL guide

`docs/dsl.md`, or `@moduledoc` on `Rete.Ruleset` — the reference a user consults while writing
rules. Every LHS form with a worked example, the gate table, guards (and where they are
evaluated, since that determines what they may reference), collection semantics **including the
empty-collection rule**, taxonomy, salience, queries, and what a RHS may return.

Include a "common mistakes" section. The engine has good error messages for several of these
already; the guide should reach users before the error does:

- referencing a variable no condition binds
- a fact binding that shadows an upstream variable
- expecting a negation to bind variables downstream
- expecting a rule to fire before `fire_rules/2`
- whatever W4 settles about guarded collections

### Design docs

`docs/design/w1-ir.md` and `w2-network.md` exist and are the internal contracts. Check them
against what actually ships — earlier phases found several stale claims, including a "known
gap" that described a feature which in fact worked. Add `w3-engine.md` if it still does not
exist (a W3 test comment already cites it).

### API docs

Every public module has a `@moduledoc` and public functions have `@doc` and `@spec`. Verify
with `mix docs` that the generated output reads coherently — grouping modules into `Rete`,
`Rete.DSL`, `Rete.Compiler` and internals will help a great deal.

---

## Part 4 — Release preparation

- **Credo** (`--strict`) and **Dialyzer**. Both will find things; fix or explicitly configure
  around them rather than lowering the bar.
- **`mix.exs`**: description, package metadata, licence, source URL, docs config. Currently the
  `mix new` skeleton plus the `taxo` dependency.
- **CHANGELOG**, and a decision on the version to publish.
- **CI**: format check, `--warnings-as-errors` compile, tests, Credo, Dialyzer.
- Consider `mix docs` output published to HexDocs.

---

## Definition of done

- The behavioural suite covers the Clara files listed above, minus the parts that genuinely do
  not apply, with each omission recorded and justified.
- Property tests pass over a few thousand generated cases, including a random op-sequence fuzz
  compared against a rebuild.
- Every mutation in the table is caught, or its survival is explained in writing.
- README, DSL guide and design docs describe what actually ships.
- Credo `--strict` and Dialyzer clean.
- `mix test`, `mix compile --force --warnings-as-errors`, `mix format --check-formatted` clean.

## Finally

Re-read the testing section of `_context.md`. On this project a green suite has three times been
hiding real bugs, and every one was found by attacking the tests rather than the code. This
phase is where that attitude pays off most: you are the last line before other people rely on it.
