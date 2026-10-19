# rete against clara-rules

Written by `bench/compare/report.exs`. `bench/compare/README.md` says what each
scenario does, how it is measured, and what the numbers do not mean.

Each timing is the mean in milliseconds for one run of the whole scenario. The `±` is
the relative standard deviation. The `×` columns are the clara mean divided by the rete
mean. The `matches` column is the count that every engine's counting query held.

## The machine

| | |
|---|---|
| date | 2026-10-19 |
| model | MacBook Pro (Mac15,9) |
| chip | Apple M3 Max |
| cores | 16 (12 Performance, 4 Efficiency) |
| memory | 64 GB |
| os | macOS 27.0.1 (26A434) |

## What ran

| | |
|---|---|
| rete | e43c29a |
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

| scenario     | n       | matches | rete        | clara-record | ×      | clara-map  | ×      |
|--------------|---------|---------|-------------|--------------|--------|------------|--------|
| calibrate    | 2000000 | 5999997 | 6.20 ±26%   | 8.88 ±1%     | 1.43   | 8.82 ±1%   | 1.42   |
| build        | 0       | 0       | 0.0090 ±51% | 1.92 ±1%     | 213.22 | 2.28 ±32%  | 253.00 |
| insert-fire  | 10000   | 10000   | 40.67 ±6%   | 133.49 ±5%   | 3.28   | 129.01 ±6% | 3.17   |
| join-keyed   | 5000    | 5000    | 33.51 ±8%   | 74.33 ±2%    | 2.22   | 71.43 ±3%  | 2.13   |
| join-one-key | 5000    | 5000    | 20.52 ±4%   | 66.80 ±4%    | 3.25   | 63.67 ±3%  | 3.10   |
| collection   | 1000    | 1000    | 9.52 ±5%    | 54.01 ±2%    | 5.67   | 52.98 ±2%  | 5.57   |
| negation     | 2000    | 2000    | 39.95 ±4%   | 89.66 ±2%    | 2.24   | 85.90 ±2%  | 2.15   |
| tms-withdraw | 2000    | 1000    | 28.10 ±4%   | 139.16 ±2%   | 4.95   | 230.99 ±1% | 8.22   |
| cascade      | 2000    | 2001    | 6.87 ±8%    | 31.86 ±4%    | 4.63   | 30.59 ±5%  | 4.45   |
| query-param  | 4000    | 20000   | 3.43 ±3%    | 12.27 ±1%    | 3.57   | 11.66 ±1%  | 3.39   |
| rule-count   | 512     | 512     | 3.64 ±7%    | 6.98 ±3%     | 1.92   | 6.52 ±2%   | 1.79   |
