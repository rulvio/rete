defmodule Rete do
  @moduledoc """
  Documentation for `Rete`.
  """

  def get_rule_data(modules) do
    Enum.flat_map(modules, & &1.get_rule_data())
  end

  def get_taxo_data(modules) do
    Enum.flat_map(modules, & &1.get_taxo_data())
  end
end
