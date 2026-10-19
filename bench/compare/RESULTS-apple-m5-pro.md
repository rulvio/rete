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
| model | MacBook Pro (Mac17,8) |
| chip | Apple M5 Pro |
| cores | 18 (6 Super, 12 Performance) |
| memory | 64 GB |
| os | macOS 27.0.1 (26A434) |

## What ran

| | |
|---|---|
| rete | 093cbbe |
| elixir | 1.20.4 |
| erlang | OTP 29, erts 17.1.1 |
| beam | jit, 64-bit, 18 schedulers |
| benchee | 1.5.1 |
| clara-rules | 1.7.0 |
| criterium | 0.4.6 |
| clojure | 1.12.6 |
| java | 25.0.2+10-LTS Corretto-25.0.2.10.1 |
| jvm | OpenJDK 64-Bit Server VM, aarch64 |
| jvm options | -XX:-OmitStackTraceInFastThrow -Xms2g -Xmx2g -XX:+AlwaysPreTouch |
| collector | G1 Young Generation, G1 Concurrent GC, G1 Old Generation |
| heap | 2048 MB max |

## Results

| scenario     | n       | matches | rete        | clara-record | ×      | clara-map  | ×      |
|--------------|---------|---------|-------------|--------------|--------|------------|--------|
| calibrate    | 2000000 | 5999997 | 3.88 ±6%    | 6.96 ±1%     | 1.79   | 7.05 ±2%   | 1.82   |
| build        | 0       | 0       | 0.0070 ±70% | 1.50 ±2%     | 214.43 | 1.71 ±29%  | 243.71 |
| insert-fire  | 10000   | 10000   | 37.56 ±11%  | 96.55 ±2%    | 2.57   | 99.98 ±3%  | 2.66   |
| join-keyed   | 5000    | 5000    | 28.78 ±10%  | 55.45 ±2%    | 1.93   | 59.15 ±3%  | 2.06   |
| join-one-key | 5000    | 5000    | 13.87 ±9%   | 48.15 ±2%    | 3.47   | 48.16 ±1%  | 3.47   |
| collection   | 1000    | 1000    | 8.30 ±10%   | 27.69 ±1%    | 3.33   | 30.39 ±2%  | 3.66   |
| negation     | 2000    | 2000    | 35.22 ±6%   | 68.72 ±4%    | 1.95   | 68.48 ±2%  | 1.94   |
| tms-withdraw | 2000    | 1000    | 22.05 ±15%  | 107.29 ±5%   | 4.86   | 155.92 ±1% | 7.07   |
| cascade      | 2000    | 2001    | 5.39 ±9%    | 22.50 ±1%    | 4.17   | 22.50 ±3%  | 4.17   |
| query-param  | 4000    | 20000   | 2.92 ±7%    | 8.79 ±1%     | 3.01   | 8.79 ±1%   | 3.01   |
| rule-count   | 512     | 512     | 2.95 ±9%    | 5.25 ±2%     | 1.78   | 5.29 ±2%   | 1.79   |
