# rete against clara-rules

Written by `bench/compare/report.exs`. `bench/compare/README.md` says what each
scenario does, how it is measured, and what the numbers do not mean.

Each timing is the mean in milliseconds for one run of the whole scenario. The `±` is
the relative standard deviation. The `×` columns are the clara mean divided by the rete
mean. The `matches` column is the count that every engine's counting query held.

## The machine

| | |
|---|---|
| date | 2026-09-24 |
| model | MacBook Pro (Mac17,8) |
| chip | Apple M5 Pro |
| cores | 18 (6 Super, 12 Performance) |
| memory | 64 GB |
| os | macOS 27.0 (26A428) |

## What ran

| | |
|---|---|
| rete | 6194680 |
| elixir | 1.20.4 |
| erlang | OTP 29, erts 17.1 |
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
| calibrate    | 2000000 | 5999997 | 3.69 ±3%    | 6.81 ±1%     | 1.85   | 7.02 ±1%   | 1.90   |
| build        | 0       | 0       | 0.0070 ±55% | 1.60 ±10%    | 228.43 | 1.78 ±26%  | 253.71 |
| insert-fire  | 10000   | 10000   | 25.50 ±7%   | 131.01 ±2%   | 5.14   | 155.46 ±3% | 6.10   |
| join-keyed   | 5000    | 5000    | 24.32 ±9%   | 72.93 ±2%    | 3.00   | 85.43 ±2%  | 3.51   |
| join-one-key | 5000    | 5000    | 13.14 ±7%   | 66.51 ±2%    | 5.06   | 77.76 ±2%  | 5.92   |
| collection   | 1000    | 1000    | 7.16 ±8%    | 33.22 ±1%    | 4.64   | 36.21 ±2%  | 5.06   |
| negation     | 2000    | 2000    | 16.75 ±14%  | 133.86 ±1%   | 7.99   | 201.17 ±1% | 12.01  |
| tms-retract  | 2000    | 0       | 26.68 ±6%   | 126.81 ±2%   | 4.75   | 186.96 ±2% | 7.01   |
| cascade      | 2000    | 2001    | 3.92 ±4%    | 29.48 ±2%    | 7.53   | 34.29 ±3%  | 8.75   |
| query-param  | 4000    | 20000   | 2.93 ±6%    | 9.08 ±2%     | 3.10   | 8.93 ±1%   | 3.05   |
| rule-count   | 512     | 512     | 2.23 ±10%   | 6.61 ±5%     | 2.97   | 6.74 ±6%   | 3.03   |
