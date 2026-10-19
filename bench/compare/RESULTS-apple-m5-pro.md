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
| rete | dda76e9 |
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
| calibrate    | 2000000 | 5999997 | 3.83 ±6%    | 7.14 ±4%     | 1.86   | 7.01 ±1%   | 1.83   |
| build        | 0       | 0       | 0.0070 ±60% | 1.77 ±25%    | 253.57 | 1.78 ±27%  | 254.00 |
| insert-fire  | 10000   | 10000   | 36.55 ±7%   | 99.23 ±4%    | 2.72   | 97.25 ±2%  | 2.66   |
| join-keyed   | 5000    | 5000    | 28.65 ±7%   | 56.65 ±2%    | 1.98   | 57.53 ±4%  | 2.01   |
| join-one-key | 5000    | 5000    | 18.25 ±7%   | 49.63 ±3%    | 2.72   | 51.88 ±4%  | 2.84   |
| collection   | 1000    | 1000    | 8.26 ±6%    | 41.72 ±6%    | 5.05   | 38.39 ±1%  | 4.65   |
| negation     | 2000    | 2000    | 34.92 ±5%   | 68.72 ±3%    | 1.97   | 72.43 ±6%  | 2.07   |
| tms-withdraw | 2000    | 0       | 30.44 ±11%  | 116.69 ±1%   | 3.83   | 197.71 ±5% | 6.50   |
| cascade      | 2000    | 2001    | 5.23 ±9%    | 24.95 ±7%    | 4.77   | 23.08 ±2%  | 4.41   |
| query-param  | 4000    | 20000   | 2.88 ±5%    | 9.65 ±7%     | 3.35   | 8.97 ±2%   | 3.12   |
| rule-count   | 512     | 512     | 3.20 ±12%   | 6.36 ±5%     | 1.99   | 5.90 ±8%   | 1.85   |
