# rete against clara-rules

This bench runs ten workloads through two engines and prints one table. `RESULTS.md` holds
the last run.

It is not `bench/run.exs`. That one measures shape, asserts on exponents, and gates CI.
This one measures milliseconds at one size, compares two engines, and gates nothing. No
figure from here belongs in `README.md`, `docs/**` or `CHANGELOG.md`, because those figures
come from `bench/run.exs`.

## Running it

```sh
bash bench/compare/run.sh          # measure, and write RESULTS.md
bash bench/compare/run.sh --smoke  # run each scenario once, and check the counts agree
```

It needs a JVM and the Clojure CLI. A full run takes a few minutes.

`clara/deps.edn` names which clara-rules to measure. A released version off Clojars is the
default:

```clojure
{com.github.gateless/clara-rules {:mvn/version "1.6.8"}}
```

A checkout on disk works too, and is what to use when measuring an unreleased change:

```clojure
{com.github.gateless/clara-rules {:local/root "/path/to/clara-rules"}}
```

`report.exs` reads whichever form is there and records it. A released version is printed as
its version, and a checkout as what `git describe` says of it. If the Clojure CLI reports
that a checkout must be prepared before use, run `clojure -X:deps prep` in it. That compiles
its Java sources.

## The parts

| file | what it does |
|---|---|
| `rete.exs` | the rete side, run by `mix run` |
| `clara/src/bench/clara.clj` | the clara side, run by `clojure -M:bench` |
| `report.exs` | joins the two result files and writes `RESULTS.md` |
| `run.sh` | the three of them, in order |
| `results/` | the raw TSV each side writes. Not committed |

## What the run records

`RESULTS.md` opens with the machine and the two runtimes, because a table of milliseconds
means nothing without them. The machine comes from `system_profiler` and `sysctl`: the
model, the chip, the core count by kind, the memory, and the OS build.

Each runtime reports itself. `rete.exs` writes its Elixir, OTP and ERTS versions and how
many schedulers the BEAM had. `clara.clj` writes its Clojure and Java versions, the JVM
name, the flags that JVM was started with, the collector it chose, and the heap ceiling. A
version read off the `PATH` instead would be the one installed, which on a machine with
more than one Java is not necessarily the one that ran.

## How the two are held to the same workload

Every ruleset carries a counting query. Each scenario reports how many matches that query
holds once the session settles, and `report.exs` refuses to print a ratio for a scenario
whose engines disagree. A ratio between two different workloads is worse than no ratio.

The counting query costs both engines something, and it is the same something. It is part
of the declared workload rather than an instrument bolted on beside it.

## The scenarios

| id | what it does | n |
|---|---|---|
| `calibrate` | an integer loop with no engine in it | 2,000,000 |
| `build` | build the rulebase from a four-rule ruleset | — |
| `insert-fire` | one rule, one condition, n facts, n conclusions | 10,000 |
| `join-keyed` | customer and order joined on id, n of each | 5,000 |
| `join-one-key` | one customer and n orders, every match under one join key | 5,000 |
| `collection` | n customers, 4 orders each, one sum per customer | 1,000 |
| `negation` | n customers with no order, then n orders in, then out again | 2,000 |
| `tms-retract` | a chain of three rules, insert n and fire, retract n and fire | 2,000 |
| `cascade` | one activation at a time, each concluding the next, n deep | 2,000 |
| `query-param` | 20,000 reads of one row out of n matches, by parameter | 4,000 |
| `rule-count` | r rules over r fact types, one match each | 512 |

Each side builds its rulebase outside the timed thunk, except in `build`, where the
rulebase is the thing being measured.

`calibrate` is not a result, and it has no rules in it. It reports how fast the process
that ran the rest of the column was going. Its cross-engine ratio means nothing, because
it compares two runtimes at arithmetic. What it is for is comparing one engine against
itself between runs: a column whose `calibrate` has moved has moved everywhere, and that
run is to be repeated rather than read.

`build` times the same phase on both sides: rule data to a live session. Both engines
expand their rule macros before it. `defrule` in rete produces IR when Elixir compiles the
module, and `defrule` in clara produces a production map when Clojure compiles the
namespace. The clara side of this bench builds its productions in `prepare`, outside the
timed thunk, so that the two start from the same place.

What separates them is runtime code generation. `mk-session` reaches
`clara.rules.compiler/compile-exprs`, which calls `eval` on the condition and action forms
of every rule. `Rete.Compiler.build/1` evaluates nothing, because Elixir emitted those as
functions when it compiled the ruleset module. That is the gap the row measures, and it is
an architectural difference rather than a measurement artefact.

Read it as one ruleset of four rules. A larger one moves the row, and this bench does not
say how.

## How each side is written

rete gets tagged tuples, which is its idiom.

clara is measured twice. `clara-record` uses `defrecord` facts, which is the clara idiom and
the faster of the two, because a field read compiles to a Java field access. `clara-map`
uses plain maps under `:fact-type-fn :type`, which is the closer mirror of a rete tagged
tuple. The gap between the two columns is what the fact shape is worth.

One piece of rule text serves both. `clara.rules.dsl/parse-rule*` builds a production from
data, so `clara.clj` writes each rule once and instantiates it per variant, with the
condition type and the constructor substituted in. A condition over a record reads its
fields by name. A condition over a map destructures them first, because
`clara.rules.compiler/get-fields` knows no field of a keyword type.

`rule-count` needs one fact type per rule. rete generates 512 rules with `Module.create/3`
and clara evaluates 512 `defrecord` forms. Both happen before anything is timed.

## The measurement

Both sides run the same protocol, written twice. Warm up for 3 seconds or 50 runs,
whichever ends first. Then collect garbage and time 11 runs. Report the median and the
minimum.

Every observation in this section was made on the machine `RESULTS.md` names: a MacBook Pro
(Mac17,8) with an Apple M5 Pro, 18 cores and 64 GB, on macOS 26.7. Another machine may
behave differently, and the checks below are worth repeating there.

The minimum is there because a JIT runtime is noisy upward and never downward. The gap
between a minimum and its median says how much of that median is noise.

The clara harness was checked against `criterium/quick-benchmark`. On `insert-fire` the
harness read a median of 92.0 ms and criterium a mean of 92.8 ms, inside its own quartiles
of 91.6 to 94.6. On `negation` the two read 135.0 ms and 130.9 ms, against quartiles of
128.5 to 137.8. The warm-up budget is long enough.

Each clara variant gets a JVM of its own. Two of them in one process share their call
sites, so whichever ran second inherited the first one's inlining decisions, and the two
columns drifted toward each other.

The JVM heap is pinned to 2 GB in `clara/deps.edn`, and pre-touched. Both matter. Without
`-XX:+AlwaysPreTouch` the first JVM started after the rete bench read about 1.6× slower
than the second, on every scenario at once, roughly one run in three. Its 2 GB of heap was
being faulted in while the pages the BEAM had just released were still being reclaimed.
Three runs with pre-touching showed no such split, and `calibrate` is there to catch it if
it returns.

## What the numbers do not say

**Two runtimes.** rete runs on the BEAM and clara runs on the JVM. Every ratio mixes engine
design with runtime design, and no column separates the two.

**A steady state, not a start.** Both sides warm up, so these are the numbers a
long-running process sees. Neither runtime's start is measured.

**No memory column.** `:erts_debug.size_shared/1` counts shared BEAM terms and a JVM heap
reading counts reachable objects. The two numbers do not divide.

**clara can go faster on one row.** `collection` uses `clara.rules.accumulators/all` and
sums in the right hand side, because a rete collection is collect-all and has no other
form. `acc/sum` is the faster clara answer, and rete has nothing to compare it against.

**Both sides run single-threaded.** rete fires at the default `concurrency: 1`, and clara
uses `fire-rules` and not `fire-rules-async`.

**Run it on a quiet machine.** The JVM side is far more sensitive to a busy one, because
its compiler and collector threads compete for the same cores. With another application
holding half a core, clara read 70% slower while rete moved by 12%. A table taken then
flatters rete. Read `calibrate` before anything else.
