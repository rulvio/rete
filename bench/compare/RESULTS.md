# rete against clara-rules

Written by `bench/compare/report.exs`. Read `bench/compare/README.md` first: it says
what each scenario does and what the numbers do not mean.

Every figure is milliseconds for one run of the whole scenario, so a smaller number is
faster. The `×` columns are clara divided by rete, so above 1.00 means rete is ahead.
The `matches` column is what each engine's counting query held after the scenario
settled. The three engines agree on it, which is what makes the comparison a comparison.

The `calibrate` row is not a result. It is an integer loop with no engine in it, and it
reports how fast the process that ran the rest of the column was going. Its own `×` says
nothing about either engine. Compare it against the same figure in an earlier run: a
column whose `calibrate` has moved has moved everywhere, and that run is to be repeated
rather than read.

## The machine

| | |
|---|---|
| date | 2026-09-22 |
| model | MacBook Pro (Mac17,8) |
| chip | Apple M5 Pro |
| cores | 18 (6 Super, 12 Performance) |
| memory | 64 GB |
| os | macOS 26.7 (25G229) |

## What ran

Each side asks its own runtime what it is and writes the answer next to its timings.
A version read off the `PATH` instead would be the one installed, and not necessarily
the one that ran.

| | |
|---|---|
| rete | b7ccf91 |
| elixir | 1.20.4 |
| erlang | OTP 29, erts 17.1 |
| beam | jit, 64-bit, 18 schedulers |
| clara-rules | 1.6.8 (Clojars) |
| clojure | 1.12.6 |
| java | 25.0.2+10-LTS Corretto-25.0.2.10.1 |
| jvm | OpenJDK 64-Bit Server VM, aarch64 |
| jvm options | -XX:-OmitStackTraceInFastThrow -Xms2g -Xmx2g -XX:+AlwaysPreTouch |
| collector | G1 Young Generation, G1 Concurrent GC, G1 Old Generation |
| heap | 2048 MB max |

A table of milliseconds only means something next to the machine that produced it. A run
on another machine overwrites this file, and that is correct.

**Run it on a quiet machine.** The JVM side is far more sensitive to a busy one than the
BEAM side, because its compiler and collector threads compete for the same cores. With
another application holding half a core, clara read 70% slower while rete moved by 12%.
A table taken then flatters rete. The `calibrate` row is how such a run is spotted.


## Medians

| scenario     | n       | matches | rete   | clara-record | ×     | clara-map | ×      |
|--------------|---------|---------|--------|--------------|-------|-----------|--------|
| calibrate    | 2000000 | 5999997 | 4.01   | 4.61         | 1.15  | 4.59      | 1.14   |
| build        | 0       | 0       | 0.0190 | 1.71         | 89.89 | 2.01      | 105.79 |
| insert-fire  | 10000   | 10000   | 43.73  | 95.21        | 2.18  | 91.78     | 2.10   |
| join-keyed   | 5000    | 5000    | 44.14  | 55.88        | 1.27  | 52.54     | 1.19   |
| join-one-key | 5000    | 5000    | 21.68  | 48.82        | 2.25  | 45.67     | 2.11   |
| collection   | 1000    | 1000    | 10.22  | 38.49        | 3.77  | 37.13     | 3.63   |
| negation     | 2000    | 2000    | 35.53  | 139.52       | 3.93  | 187.11    | 5.27   |
| tms-retract  | 2000    | 0       | 42.33  | 114.86       | 2.71  | 141.02    | 3.33   |
| cascade      | 2000    | 2001    | 11.19  | 22.61        | 2.02  | 21.22     | 1.90   |
| query-param  | 4000    | 20000   | 3.03   | 9.19         | 3.04  | 8.88      | 2.93   |
| rule-count   | 512     | 512     | 3.98   | 6.70         | 1.68  | 5.96      | 1.50   |

## Minimums

The least noisy reading of the eleven. A JIT runtime is noisy upward and never
downward, so the gap between a minimum and its median is how much of that median
is noise.

| scenario     | n       | matches | rete   | clara-record | ×      | clara-map | ×      |
|--------------|---------|---------|--------|--------------|--------|-----------|--------|
| calibrate    | 2000000 | 5999997 | 3.63   | 4.56         | 1.26   | 4.56      | 1.26   |
| build        | 0       | 0       | 0.0140 | 1.53         | 109.64 | 1.64      | 117.36 |
| insert-fire  | 10000   | 10000   | 42.21  | 94.60        | 2.24   | 90.05     | 2.13   |
| join-keyed   | 5000    | 5000    | 42.36  | 55.22        | 1.30   | 51.67     | 1.22   |
| join-one-key | 5000    | 5000    | 21.30  | 48.04        | 2.26   | 44.65     | 2.10   |
| collection   | 1000    | 1000    | 9.96   | 38.03        | 3.82   | 36.84     | 3.70   |
| negation     | 2000    | 2000    | 33.25  | 135.84       | 4.09   | 184.18    | 5.54   |
| tms-retract  | 2000    | 0       | 41.58  | 111.44       | 2.68   | 138.68    | 3.34   |
| cascade      | 2000    | 2001    | 10.81  | 22.06        | 2.04   | 20.89     | 1.93   |
| query-param  | 4000    | 20000   | 2.65   | 9.06         | 3.42   | 8.77      | 3.31   |
| rule-count   | 512     | 512     | 3.76   | 6.51         | 1.73   | 5.86      | 1.56   |

## What this does not say

**Two runtimes.** rete runs on the BEAM and clara runs on the JVM. Every ratio here
mixes engine design with runtime design, and no column separates the two.

**A steady state, not a start.** Each side warms up before it times anything, so these
are the numbers a long-running process sees. Neither the JVM's start nor the BEAM's is
measured.

**No memory column.** `:erts_debug.size_shared/1` counts shared BEAM terms and a JVM
heap reading counts reachable objects. The two numbers do not divide.

**The build row is one ruleset, of four rules.** Both engines expand their rule macros
ahead of it, so what it times is the same phase on both sides: rule data to a live
session. The gap is runtime code generation. `mk-session` evaluates the condition and
action forms of each rule, and rete has nothing to evaluate, because Elixir emitted
those as functions when it compiled the ruleset module. A larger ruleset moves this row,
and nothing here says how.

**clara can go faster on one row.** The `collection` scenario uses
`clara.rules.accumulators/all` and sums in the right hand side, because a rete collection
is collect-all and has no other form. `acc/sum` is the faster clara answer, and it has no
counterpart here.
