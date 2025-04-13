defmodule Rete do
  @moduledoc """
  Documentation for `Rete`.
  """

  @doc """
  """
  def get_expr_data(modules) do
    Enum.map(modules, & &1.get_expr_data())
    |> Enum.reduce(%{}, fn expr_map, acc -> Map.merge(acc, expr_map) end)
  end

  @doc """
  """
  def get_rule_data(modules) do
    Enum.flat_map(modules, & &1.get_rule_data())
  end

  @doc """
  """
  def get_taxo_data(modules) do
    Enum.flat_map(modules, & &1.get_taxo_data())
  end
end
