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

## Comment density

The section above says how a comment reads. This one says whether to write it at all.

A comment carries the reason behind a decision. It does not restate the line below it.
`timeout-minutes: 15` explains itself, so a comment on it is noise, and noise dilutes the
comments that do carry a reason.

Density varies by file, and it varies a lot. `lib/**/*.ex` comments heavily, because the
engine holds decisions the code cannot show. Why a memory is indexed the other way is one.
Config and infra files hold almost none. `.github/workflows/ci.yml`, `mix.exs` and
`.formatter.exs` take a comment only where a choice is invisible, such as why
`cache/restore` replaces `cache`.

Match the file you are in. Heavy commenting in the source is not a licence to comment at
that density everywhere. A mechanical change applied across several places takes no block
comment to introduce it.

To check after an edit, read each comment you added without the code under it. One that
tells you nothing new is one to delete.

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
