defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  **Internal.** Not part of the public API, and documented rather than hidden because
  durability, checkpointing and scheduling work will need to reach in here. Treat its
  functions as liable to change.

  Ordering is `{salience, internal_salience}` descending, then compile order ascending.
  Two matches of the same rule fire in the order they arrived.

  Every activation of one production node shares a sort key, so the agenda is a small
  number of ordered buckets rather than one sorted list. `add/2` and `pop/1` are O(1).
  `remove/2` is linear in one bucket, which holds one rule's pending matches. See
  `docs/design/engine.md` §7.

      iex> alias Rete.{Activation, Agenda}
      iex> urgent = %Activation{node_id: :n1, salience: 10}
      iex> normal = %Activation{node_id: :n2, salience: 0}
      iex> agenda = Agenda.new() |> Agenda.add(normal) |> Agenda.add(urgent)
      iex> Agenda.to_list(agenda) |> Enum.map(& &1.node_id)
      [:n1, :n2]
  """

  alias Rete.Activation

  @type key :: {integer(), integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          keys: [key()],
          buckets: %{key() => :queue.queue(Activation.t())},
          size: non_neg_integer()
        }

  defstruct keys: [], buckets: %{}, size: 0

  @doc "An empty agenda."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  How many activations are waiting.

  Counted as they arrive, so that reporting the size of a runaway agenda is cheap.

      iex> alias Rete.{Activation, Agenda}
      iex> Agenda.new() |> Agenda.add(%Activation{node_id: :n1}) |> Agenda.size()
      1
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Adds an activation, behind the ones already queued for its rule."
  @spec add(t(), Activation.t()) :: t()
  def add(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    case Map.fetch(agenda.buckets, key) do
      {:ok, bucket} ->
        %__MODULE__{
          agenda
          | buckets: Map.put(agenda.buckets, key, :queue.in(activation, bucket)),
            size: agenda.size + 1
        }

      :error ->
        %__MODULE__{
          keys: insert_key(agenda.keys, key),
          buckets: Map.put(agenda.buckets, key, :queue.from_list([activation])),
          size: agenda.size + 1
        }
    end
  end

  @doc """
  Removes an activation by value.

  Returns `{agenda, :removed}` when it was still pending, `{agenda, :missing}` when it had
  already fired. The caller must tell the two apart. An activation that never fired
  inserted nothing, so there is nothing to retract. One that fired has facts that truth
  maintenance must take back.

      iex> alias Rete.{Activation, Agenda}
      iex> pending = %Activation{node_id: :n1}
      iex> {_agenda, verdict} = Agenda.new() |> Agenda.add(pending) |> Agenda.remove(pending)
      iex> verdict
      :removed
      iex> {_agenda, verdict} = Agenda.remove(Agenda.new(), pending)
      iex> verdict
      :missing
  """
  @spec remove(t(), Activation.t()) :: {t(), :removed | :missing}
  def remove(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    with {:ok, bucket} <- Map.fetch(agenda.buckets, key),
         {:ok, rest} <- drop_first(:queue.to_list(bucket), activation) do
      {store(agenda, key, :queue.from_list(rest)), :removed}
    else
      _ -> {agenda, :missing}
    end
  end

  @doc """
  Takes the most salient activation, or `:empty`.

      iex> Rete.Agenda.pop(Rete.Agenda.new())
      :empty
  """
  @spec pop(t()) :: {:ok, Activation.t(), t()} | :empty
  def pop(%__MODULE__{keys: []}), do: :empty

  def pop(%__MODULE__{keys: [key | _]} = agenda) do
    {{:value, activation}, rest} = agenda.buckets |> Map.fetch!(key) |> :queue.out()

    {:ok, activation, store(agenda, key, rest)}
  end

  @doc """
  Takes every activation of the most salient **group**, or `:empty`.

  A group is every bucket sharing the leading `{salience, internal_salience}` of the sort
  key, so it spans the rules that would fire before any less salient one. Activations come
  back in firing order, exactly as repeated `pop/1` would yield them.

      iex> alias Rete.{Activation, Agenda}
      iex> agenda =
      ...>   Agenda.new()
      ...>   |> Agenda.add(%Activation{node_id: :a, salience: 10, order: 0})
      ...>   |> Agenda.add(%Activation{node_id: :b, salience: 10, order: 1})
      ...>   |> Agenda.add(%Activation{node_id: :c, salience: 0, order: 2})
      iex> {:ok, group, rest} = Agenda.pop_group(agenda)
      iex> {Enum.map(group, & &1.node_id), Agenda.size(rest)}
      {[:a, :b], 1}
  """
  @spec pop_group(t()) :: {:ok, [Activation.t()], t()} | :empty
  def pop_group(%__MODULE__{keys: []}), do: :empty

  def pop_group(%__MODULE__{keys: [{salience, internal, _order} | _]} = agenda) do
    {keys, rest_keys} =
      Enum.split_while(agenda.keys, fn {s, i, _order} -> s == salience and i == internal end)

    activations = Enum.flat_map(keys, &(agenda.buckets |> Map.fetch!(&1) |> :queue.to_list()))

    {:ok, activations,
     %__MODULE__{
       keys: rest_keys,
       buckets: Map.drop(agenda.buckets, keys),
       size: agenda.size - length(activations)
     }}
  end

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{keys: keys, buckets: buckets}) do
    Enum.flat_map(keys, fn key -> buckets |> Map.fetch!(key) |> :queue.to_list() end)
  end

  # Drops the key when the bucket empties. `keys` records which buckets exist, so an empty
  # one left behind would make `pop/1` reach for a value that is not there.
  #
  # Takes a queue, not a list. Round-tripping through `:queue.to_list/1` here would put an
  # O(bucket) cost on `pop/1`, which has to stay O(1).
  defp store(%__MODULE__{} = agenda, key, remaining) do
    if :queue.is_empty(remaining) do
      %__MODULE__{
        keys: List.delete(agenda.keys, key),
        buckets: Map.delete(agenda.buckets, key),
        size: agenda.size - 1
      }
    else
      %__MODULE__{
        agenda
        | buckets: Map.put(agenda.buckets, key, remaining),
          size: agenda.size - 1
      }
    end
  end

  # The key list is as long as the ruleset has production nodes, so a linear insertion
  # costs nothing that grows with the session.
  defp insert_key([], key), do: [key]

  defp insert_key([head | tail] = keys, key) do
    if key < head, do: [key | keys], else: [head | insert_key(tail, key)]
  end

  # Two activations are the same when they are the same rule reached by the same match.
  # `:order` and the salience fields come from the node, so they cannot differ when the
  # node does not. That is also why the one looked for lands in the bucket of the one
  # stored.
  defp drop_first([], _activation), do: :error

  defp drop_first([head | tail], activation) do
    if same?(head, activation) do
      {:ok, tail}
    else
      case drop_first(tail, activation) do
        {:ok, rest} -> {:ok, [head | rest]}
        :error -> :error
      end
    end
  end

  defp same?(a, b), do: a.node_id == b.node_id and a.token == b.token
end
