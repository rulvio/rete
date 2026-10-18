# rete against clara-rules

Written by `bench/compare/report.exs`. `bench/compare/README.md` says what each
scenario does, how it is measured, and what the numbers do not mean.

Each timing is the mean in milliseconds for one run of the whole scenario. The `±` is
the relative standard deviation. The `×` columns are the clara mean divided by the rete
mean. The `matches` column is the count that every engine's counting query held.

## The machine

| | |
|---|---|
| date | 2026-10-18 |
| model | MacBook Pro (Mac15,9) |
| chip | Apple M3 Max |
| cores | 16 (12 Performance, 4 Efficiency) |
| memory | 64 GB |
| os | macOS 27.0.1 (26A434) |

## What ran

| | |
|---|---|
| rete | 902056d |
| elixir | 1.20.4 |
| erlang | OTP 29, erts 17.1.1 |
| beam | jit, 64-bit, 16 schedulers |
| benchee | 1.5.1 |
| clara-rules | 1.7.0 |
| criterium | 0.4.6 |
| clojure | 1.12.6 |
| java | 25.0.1+8-LTS-27  |
| jvm | Java HotSpot(TM) 64-Bit Server VM, aarch64 |
| jvm options | -XX:-OmitStackTraceInFastThrow -Xms2g -Xmx2g -XX:+AlwaysPreTouch |
| collector | G1 Young Generation, G1 Concurrent GC, G1 Old Generation |
| heap | 2048 MB max |

## Results

| scenario     | n       | matches | rete         | clara-record | ×      | clara-map  | ×      |
|--------------|---------|---------|--------------|--------------|--------|------------|--------|
| calibrate    | 2000000 | 5999997 | 6.01 ±2%     | 8.80 ±1%     | 1.46   | 9.26 ±3%   | 1.54   |
| build        | 0       | 0       | 0.0100 ±168% | 1.98 ±27%    | 198.40 | 2.34 ±11%  | 233.90 |
| insert-fire  | 10000   | 10000   | 48.49 ±12%   | 124.42 ±4%   | 2.57   | 137.09 ±5% | 2.83   |
| join-keyed   | 5000    | 5000    | 35.06 ±7%    | 68.96 ±3%    | 1.97   | 81.47 ±3%  | 2.32   |
| join-one-key | 5000    | 5000    | 21.82 ±5%    | 61.24 ±2%    | 2.81   | 66.83 ±4%  | 3.06   |
| collection   | 1000    | 1000    | 10.17 ±6%    | 54.82 ±2%    | 5.39   | 53.46 ±2%  | 5.26   |
| negation     | 2000    | 2000    | 31.15 ±5%    | 162.42 ±1%   | 5.21   | 259.38 ±2% | 8.33   |
| tms-retract  | 2000    | 0       | 38.12 ±5%    | 140.42 ±5%   | 3.68   | 253.73 ±5% | 6.66   |
| cascade      | 2000    | 2001    | 7.45 ±7%     | 30.00 ±4%    | 4.03   | 30.66 ±2%  | 4.11   |
| query-param  | 4000    | 20000   | 3.60 ±5%     | 11.97 ±1%    | 3.33   | 11.90 ±1%  | 3.30   |
| rule-count   | 512     | 512     | 3.84 ±7%     | 6.53 ±4%     | 1.70   | 6.96 ±5%   | 1.81   |
