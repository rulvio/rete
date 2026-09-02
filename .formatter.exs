# Used by "mix format"

# The DSL reads as declarations, not calls: `defrule name(conditions) do ... end`.
# Without this the formatter rewrites that to `defrule(name(conditions), do: ...)`,
# which is the same AST but loses the shape the DSL exists for. Exported so that
# projects depending on :rete inherit it and their rulesets format the same way.
locals_without_parens = [
  defrule: 1,
  defrule: 2,
  defquery: 1,
  defquery: 2,
  derive: 2,
  underive: 2,
  index: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{bench,config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
