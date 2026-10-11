defmodule Rete.ImageTest do
  @moduledoc """
  The failures of an image compile that no ruleset causes.

  Not async, because two tests change the application environment. Every ruleset that
  compiles meanwhile reads `:image_compile_timeout`, and every build reads `:images`.
  """

  use ExUnit.Case, async: false

  alias Rete.Image.Guard

  # The ruleset module compiles inside the same call. A failure that escaped would stop it.
  # The doctest of `Rete.Image.Guard` covers a raise and a plain result.
  describe "Guard.run/1" do
    test "a throw becomes an error" do
      assert {:error, message} = Guard.run(fn -> throw(:ball) end)
      assert message =~ "throw"
    end

    test "an exit becomes an error" do
      assert {:error, message} = Guard.run(fn -> exit(:gone) end)
      assert message =~ "exit"
    end
  end

  test "an image that does not compile in time stops a build with images" do
    previous = Application.fetch_env(:rete, :image_compile_timeout)
    Application.put_env(:rete, :image_compile_timeout, 0)

    source = """
    defmodule Rete.ImageTest.Slow do
      use Rete.Ruleset
      defrule flag({:order, cid, _amt}), do: {:flagged, cid}
    end
    """

    try do
      [{module, _beam}] = Code.compile_string(source)
      assert {:unavailable, reason} = module.__rete_image__()
      assert reason =~ "did not compile in 0 ms"

      error = assert_raise ArgumentError, fn -> Rete.Session.new([module]) end
      assert error.message =~ "did not compile in 0 ms"

      session =
        [module]
        |> Rete.Session.new(images: false)
        |> Rete.Session.insert({:order, 1, 5})
        |> Rete.Session.fire_rules()

      assert {:flagged, 1} in Rete.Session.facts(session)
    after
      case previous do
        {:ok, value} -> Application.put_env(:rete, :image_compile_timeout, value)
        :error -> Application.delete_env(:rete, :image_compile_timeout)
      end
    end
  end

  # A test env turns images off in its config, so that a coverage tool sees the rules run.
  test "the :images environment sets the default of a build" do
    [{module, _beam}] =
      Code.compile_string("""
      defmodule Rete.ImageTest.Default do
        use Rete.Ruleset
        defrule flag({:order, cid, _amt}), do: {:flagged, cid}
      end
      """)

    {:ok, {image, _beam}} = module.__rete_image__()
    previous = Application.fetch_env(:rete, :images)
    Application.put_env(:rete, :images, false)

    try do
      assert {:ok, off} = Rete.Image.captures(Rete.Compiler.build([module]))
      assert module in off and image not in off

      assert {:ok, on} = Rete.Image.captures(Rete.Compiler.build([module], images: true))
      assert image in on and module not in on
    after
      case previous do
        {:ok, value} -> Application.put_env(:rete, :images, value)
        :error -> Application.delete_env(:rete, :images)
      end
    end
  end
end
