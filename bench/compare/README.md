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
bash bench/compare/run.sh --smoke  # run each scenario once, check the counts, print the table
```

A smoke run times nothing and writes no `RESULTS.md`. It prints the table with its timing
cells empty, and fails if the engines disagree on a count.

It needs a JVM and the Clojure CLI. It runs on macOS and on Linux.

`clara/deps.edn` names which released clara-rules to measure. It also pins Clojure, so the
installed Clojure CLI does not choose the version. The clara side reads the clara-rules
version it loaded off the jar, and `RESULTS.md` records that version.

## The parts

| file | what it does |
|---|---|
| `rete.exs` | the rete side, run by `mix run`, measured by Benchee |
| `clara/src/bench/clara.clj` | the clara side, run by `clojure -M:bench`, measured by Criterium |
| `report.exs` | joins the result files and writes `RESULTS.md` |
| `run.sh` | the three of them, in order |
| `results/` | the raw TSV each side writes. Not committed |

## What the run records

`RESULTS.md` opens with the machine and the two runtimes, because a table of milliseconds
means nothing without them. On macOS the machine comes from `system_profiler`, `sysctl` and
`sw_vers`. On Linux it comes from `lscpu`, `nproc`, `/proc/meminfo`, `/etc/os-release` and
`uname`. A row that the machine does not report reads "unknown".

Each runtime reports itself. `rete.exs` writes its Elixir, OTP and ERTS versions, how many
schedulers the BEAM had, and the Benchee version. `clara.clj` writes the clara-rules and
Criterium versions, its Clojure and Java versions, and the JVM name. It also writes the
flags that JVM was started with, the collector it chose, and the heap ceiling. A version
read off the `PATH` instead would be the one installed. On a machine with more than one
Java, that is not necessarily the one that ran.

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
| `build` | build a live session from a four-rule ruleset | — |
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
itself between runs. A column whose `calibrate` has moved has moved everywhere, and that
run is to be repeated rather than read.

`build` times the same phase on both sides: rule data to a live session. On the rete side
that is `Rete.Compiler.build/1` and then `Rete.Session.from_network/1`. On the clara side
it is `mk-session`. Both engines expand their rule macros before it. `defrule` in rete
produces IR when Elixir compiles the module, and `defrule` in clara produces a production
map when Clojure compiles the namespace. The clara side of this bench builds its
productions in `prepare`, outside the timed thunk, so that the two start from the same
place.

The two engines do different work in that phase. `mk-session` reaches
`clara.rules.compiler/compile-exprs`, which calls `eval` on the condition and action forms
of every rule. `Rete.Compiler.build/1` evaluates nothing, because Elixir emitted those as
functions when it compiled the ruleset module.

The row covers one ruleset of four rules. A larger one moves the row, and this bench does
not say how.

## How each side is written

rete gets tagged tuples, which is its idiom.

clara is measured twice. `clara-record` uses `defrecord` facts, which is the clara idiom.
A field read on a record compiles to a Java field access. `clara-map` uses plain maps under
`:fact-type-fn :type`, which is the closer mirror of a rete tagged tuple. The gap between
the two columns is what the fact shape is worth.

One piece of rule text serves both. `clara.rules.dsl/parse-rule*` builds a production from
data, so `clara.clj` writes each rule once and instantiates it per variant, with the
condition type and the constructor substituted in. A condition over a record reads its
fields by name. A condition over a map destructures them first, because
`clara.rules.compiler/get-fields` knows no field of a keyword type.

`rule-count` needs one fact type per rule. rete generates 512 rules with `Module.create/3`
and clara evaluates 512 `defrecord` forms. Both happen before anything is timed.

## The measurement

Each side uses the standard benchmark tool of its runtime. The tool does the warm-up, the
sampling and the statistics.

The clara side uses Criterium's `quick-benchmark` with its defaults. It warms the JIT up
for 5 seconds and then takes 6 samples. Each sample is a batch of runs, sized so that the
batch runs long enough to time.

The clara `build` row is the one exception. Criterium ends its warm-up only once the JVM
stops loading classes. `mk-session` calls `eval`, so every run loads new classes and that
warm-up never ends. This row takes a plain timer instead. It warms up for 5 seconds, then
times 100 runs one at a time.

The rete side uses Benchee with a 2 second warm-up and 5 seconds of measurement. The BEAM
JIT compiles a module when it loads it, so the warm-up has less to do than on the JVM.

Both report a mean and a relative standard deviation, and the table prints both. The two
spreads are not the same statistic. Criterium computes its spread over samples that are
each a batch of runs. Benchee and the plain timer compute it over single runs. A batch averages out some
of the noise, so the clara spread reads narrower for the same noise.

Each clara variant gets a JVM of its own. Two of them in one process share their call
sites. Whichever ran second would inherit the first one's inlining decisions, and the two
columns would drift toward each other.

The JVM heap is pinned to 2 GB in `clara/deps.edn`, so heap growth does not land in a
timing. It is also pre-touched with `-XX:+AlwaysPreTouch`, so the JVM faults its heap pages
in at start and not during a timed run. This matters most for the first JVM after the rete
side. The pages that the BEAM just released can still be in reclaim when that JVM starts.

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

**Run it on a quiet machine.** The JVM side is more sensitive to a busy machine than the
BEAM side. Its compiler and collector threads compete with the benchmark for the same
cores, so a busy machine slows clara more than rete. Read `calibrate` before anything else.
