defmodule Rete.ImageTest.BadImage do
  @moduledoc false
  # Offers an image whose beam does not load.
  def __rete_image__, do: {:ok, {:"Elixir.Rete.ImageTest.BadImage.Image.M0123456789ABCDEF", "no"}}
end

defmodule Rete.ImageTest do
  @moduledoc """
  The failures of an image compile, and of an image load, that no ruleset causes.

  Not async, because two tests change the application environment. Every ruleset that
  compiles meanwhile reads `:image_compile_timeout`, and every build reads `:images`.
  """

  use ExUnit.Case, async: false

  alias Rete.Image.Builder

  # The ruleset module compiles inside the same call. A failure that escaped would stop it.
  describe "Builder.guard/1" do
    test "a result passes through" do
      assert {:ok, 1} == Builder.guard(fn -> {:ok, 1} end)
    end

    test "a raise becomes an error" do
      assert {:error, "boom"} == Builder.guard(fn -> raise "boom" end)
    end

    test "a throw becomes an error" do
      assert {:error, message} = Builder.guard(fn -> throw(:ball) end)
      assert message =~ "throw"
    end

    test "an exit becomes an error" do
      assert {:error, message} = Builder.guard(fn -> exit(:gone) end)
      assert message =~ "exit"
    end
  end

  test "a build with images raises when an image does not load" do
    productions =
      [Rete.Doc.Orders]
      |> Rete.get_rule_data()
      |> Enum.map(&%{&1 | module: Rete.ImageTest.BadImage})

    error = assert_raise ArgumentError, fn -> Rete.Compiler.build_productions(productions) end
    assert error.message =~ "Cannot build the network."
    assert error.message =~ "did not load"
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
      assert {:no_image, detail} = module.__rete_image__()
      assert detail =~ "did not compile in 0 ms"

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
