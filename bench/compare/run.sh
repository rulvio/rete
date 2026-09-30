#!/usr/bin/env bash
#
# The whole comparison. Run it from anywhere:
#
#   bash bench/compare/run.sh          measure, and write RESULTS.md
#   bash bench/compare/run.sh --smoke  run each scenario once, and check the counts agree
#
# See README.md in this directory.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

mix run bench/compare/rete.exs "$@"

# A JVM for each variant. Two of them in one process share their call sites, and whichever
# ran second inherited the first one's inlining decisions.
(cd bench/compare/clara && clojure -M:bench record "$@")
(cd bench/compare/clara && clojure -M:bench map "$@")

elixir bench/compare/report.exs "$@"
