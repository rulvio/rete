# CLAUDE.md

## Documentation style

The prose in this repository is **ASD-STE100 Simplified Technical English**: short
sentences, one statement in each sentence, the active voice, common words, and no
metaphors or idioms. Technical terms and domain terms are fine.

This covers `README.md`, `docs/**`, `@moduledoc` and `@doc` strings, code comments, and
the text of raised errors. An error message is documentation that a person reads at the
worst moment, so it follows the same rules.

When the global rule says "match existing style", this is the existing style. Measured
over the corpus: average sentence length 11.7 to 14.4 words, no sentence above 30 words,
and no semicolons. Keep it that way.

To check after an edit, count the words in each sentence of the prose you changed. A
sentence above 30 words needs to be two sentences.

## Performance figures

A figure in the prose comes from a scenario in `bench/run.exs`, which `mix bench` runs.
This covers a duration, a memory size, a count and a ratio. It covers `README.md`,
`docs/**`, `CHANGELOG.md`, and doc strings. Add the scenario first, then write the number
it prints.

Write the mechanism when you cannot measure it. A number that nobody can reproduce says
less than the reason behind it. A comparison against deleted code is one of these cases.
The old side is gone, so no benchmark reaches it, and the claim needs prose instead of a
table.

Publish only what the measurement supports. Round to the precision of the run. If a column
moves more between two runs of one shape than between the shapes you compare, it carries no
signal. Drop the column, and say what the bench shows.

Figures in a released `CHANGELOG.md` section record what was true for that release. Leave
them alone. A rewrite of the prose around a figure does not re-open the measurement.

To check after an edit, name the scenario behind each figure you wrote. Run `mix bench` and
read the number off its output.
