defmodule Rete do
  @moduledoc """
  Documentation for `Rete`.
  """

  @doc """
  Retrieves expression data from the given modules.
  Combines and deduplicates the data based on the expression form.
  """
  def get_expr_data(modules) do
    Enum.map(modules, & &1.get_expr_data())
    |> Enum.reduce([], &Enum.concat/2)
    |> Enum.uniq_by(fn {expr_form, _} -> expr_form end)
  end

  @doc """
  Retrieves rule data from the given modules.
  Combines all the rule data into a single list.
  """
  def get_rule_data(modules) do
    Enum.flat_map(modules, & &1.get_rule_data())
  end

  @doc """
  Retrieves taxonomy data from the given modules.
  Combines all the taxonomy data into a single list.
  """
  def get_taxo_data(modules) do
    Enum.flat_map(modules, & &1.get_taxo_data())
  end
end
