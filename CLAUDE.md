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
