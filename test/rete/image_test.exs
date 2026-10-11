defmodule Rete.ImageTest do
  @moduledoc """
  The failures of an image compile that no ruleset causes.

  Not async, because one test changes `:image_compile_timeout` in the application
  environment, and every ruleset that compiles meanwhile reads it.
  """

  use ExUnit.Case, async: false

  alias Rete.Image.Guard

  # The ruleset module compiles inside the same call. A failure that escaped would stop it.
  describe "Guard.run/1" do
    test "a raise becomes an error" do
      assert {:error, "boom"} == Guard.run(fn -> raise "boom" end)
    end

    test "a throw becomes an error" do
      assert {:error, message} = Guard.run(fn -> throw(:ball) end)
      assert message =~ "throw"
    end

    test "an exit becomes an error" do
      assert {:error, message} = Guard.run(fn -> exit(:gone) end)
      assert message =~ "exit"
    end

    test "a result passes through" do
      assert {:ok, 1} == Guard.run(fn -> {:ok, 1} end)
    end
  end

  test "an image that does not compile in time leaves the module without an image" do
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
    after
      Application.delete_env(:rete, :image_compile_timeout)
    end
  end
end
