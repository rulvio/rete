# Phase prompts

The standalone prompts each phase of this project was built from. Each is self-contained:
hand one to a fresh session with no prior context and it has everything it needs. They are
kept as a record of what was asked for and why, not as work still to do.

| Prompt | Phase | State |
|---|---|---|
| [w4-semantic-gaps.md](w4-semantic-gaps.md) | Collection ordering and xor semantics | **done** |
| [w5-observability.md](w5-observability.md) | Listeners, loop detection, session inspection and explanations | **done** |
| [w6-hardening.md](w6-hardening.md) | Behavioural suite mined from Clara, property tests, docs, release prep | **done** |

[_context.md](_context.md) is the briefing common to all of them.

The contracts the code is written against are the design docs, and those *are* current:

* [../design/w1-ir.md](../design/w1-ir.md) — the IR and the DSL front end
* [../design/w2-network.md](../design/w2-network.md) — the compiled network
* [../design/w3-engine.md](../design/w3-engine.md) — the engine
* [../design/w5-observability.md](../design/w5-observability.md) — listeners, inspection, the loop guard

## State as of the last session

W1 (DSL front end), W2 (compiler and network), W3 (engine), W4 (semantic gaps),
W5 (observability) and W6 (hardening, docs and release prep) are all complete and green:

* **652 tests** (626 tests, 16 properties, 10 doctests), ~4.9 s;
* `mix compile --force --warnings-as-errors` clean;
* `mix format --check-formatted` clean;
* `mix credo --strict` clean;
* `mix dialyzer` clean;
* `mix docs` clean, no warnings.

Shipped as **0.1.0**. `README.md`, `docs/dsl.md` and `CHANGELOG.md` are written, and
`mix.exs` carries the package metadata for Hex.

Nothing is committed. Everything is in the working tree.
