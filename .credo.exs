# Credo configuration.
#
# Everything not mentioned here keeps its default, so this file is only the
# places where the default is wrong *for this codebase* — and each of them says
# why. `strict: true` is set, so `mix credo` and `mix credo --strict` agree.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      # `extra:` overrides the parameters of a default check and leaves every
      # other check exactly as it comes. Listing checks under `enabled:` would
      # replace the whole default set instead.
      checks: %{
        extra: [
          # A fold whose reducer is a `case` is depth 3, and that is the shape
          # most of this engine is written in:
          #
          #     Enum.reduce(items, {state, ops}, fn item, {state, ops} ->
          #       case ... do
          #
          # Pulling the reducer out into a named function to reach depth 2 hides
          # the accumulator behind a name and reads worse, not better. Depth 4
          # is still reported, and there is none.
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]}
        ],
        disabled: []
      }
    }
  ]
}
