defmodule Rete.Engine.State do
  @moduledoc """
  Everything that changes while rules fire, as one value threaded through the
  propagation loop.

  Clara propagates by mutating a transient memory and calling down the node tree.
  Here a node is a function of state and returns the state plus the work it
  produced, and the loop does the walking. That is what removes the need for a
  transport abstraction and four activation protocols, keeps propagation flat
  rather than deeply recursive, and leaves one place — the loop — where W5 can
  emit listener events.
  """

  alias Rete.Agenda
  alias Rete.Memory
  alias Rete.Network

  @typedoc """
  A unit of pending propagation.

  `:left` carries tokens from a parent, `:right` carries elements from an alpha.
  """
  @type op ::
          {:left | :left_retract, term(), [Rete.Token.t()]}
          | {:right | :right_retract, term(), [Rete.Element.t()]}

  @type t :: %__MODULE__{
          network: Network.t(),
          memory: Memory.t(),
          agenda: Agenda.t(),
          queue: :queue.queue(op()),
          order: %{term() => non_neg_integer()},
          fired: non_neg_integer()
        }

  defstruct [:network, :memory, :agenda, :queue, order: %{}, fired: 0]

  @doc """
  A state over a network, with empty memory and nothing pending.

  `:order` is the compile position of each production, so that two activations of
  equal salience fire in the order the rules were written.
  """
  @spec new(Network.t()) :: t()
  def new(%Network{} = network) do
    order =
      network
      |> Network.beta_nodes()
      |> Enum.filter(&match?(%Network.Node.Production{}, &1))
      |> Enum.sort_by(& &1.id)
      |> Enum.with_index()
      |> Map.new(fn {node, index} -> {node.id, index} end)

    %__MODULE__{
      network: network,
      memory: Memory.new(),
      agenda: Agenda.new(),
      queue: :queue.new(),
      order: order
    }
  end

  @doc "Appends propagation work."
  @spec enqueue(t(), [op()]) :: t()
  def enqueue(state, []), do: state

  def enqueue(%__MODULE__{queue: queue} = state, ops) do
    %__MODULE__{state | queue: Enum.reduce(ops, queue, &:queue.in/2)}
  end

  @doc "Takes the next unit of work, or `:empty`."
  @spec dequeue(t()) :: {:ok, op(), t()} | :empty
  def dequeue(%__MODULE__{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, op}, rest} -> {:ok, op, %__MODULE__{state | queue: rest}}
      {:empty, _} -> :empty
    end
  end
end
