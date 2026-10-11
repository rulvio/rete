defmodule Rete.Image.Guard do
  @moduledoc """
  Runs a step of an image compile so that no failure escapes from it.

  **Internal.** `Rete.Image` builds an image inside the compile of the ruleset module. A
  raise, a throw or an exit that escaped would stop that compile. An image must never stop
  the ruleset module from compiling. See `docs/design/snapshot.md` §2.

  This is a module of its own so that a test can reach each kind of failure. No ruleset
  causes a throw or an exit in the image compile.
  """

  @doc """
  Runs `fun`, and returns its result. A raise, a throw or an exit becomes
  `{:error, message}`.

      iex> Rete.Image.Guard.run(fn -> {:ok, 1} end)
      {:ok, 1}
      iex> Rete.Image.Guard.run(fn -> raise "boom" end)
      {:error, "boom"}
  """
  @spec run((-> {:ok, term()} | {:error, String.t()})) :: {:ok, term()} | {:error, String.t()}
  def run(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end
end
