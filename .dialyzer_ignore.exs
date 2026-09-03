# Warnings that are the intended behavior rather than a defect.
#
# `list_unused_filters: true` is set in mix.exs, so an entry that stops matching
# is reported instead of quietly rotting.
[
  # `Rete.Ruleset.defrule/1` and `defquery/1` are the clauses a production
  # written without a `do` block falls into. They raise, naming the rule,
  # because there is nothing sensible to generate — so having no local return is
  # exactly the point. Elixir rejects `@dialyzer {:nowarn_function, defrule: 1}`
  # outright ("only macros are supported" is not a thing it allows), which is
  # why this is here rather than next to the definition.
  {"lib/rete/ruleset.ex", :no_return}
]
