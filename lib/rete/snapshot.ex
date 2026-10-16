defmodule Rete.Snapshot do
  @moduledoc """
  The binary format behind `Rete.Session.dump/2` and `Rete.Session.load/2`.

  **Internal.** It holds the envelope, the signature, the decode, and the choice of images
  to carry. `Rete.Image` holds the images. See `docs/design/snapshot.md` §3 and §4.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Engine.State
  alias Rete.Image
  alias Rete.Network
  alias Rete.Network.Node

  # Increase this when an engine struct changes. The struct-shape test in `snapshot_test.exs`
  # fails until it does. Increase it also when the contract of `Negation.marker/2`,
  # `marker_alpha/1` or `Taxonomy.default_fact_type/1` changes. No test catches that. The
  # envelope and the MAC input never change, so an older release can still report
  # `{:format, n}`.
  @format 1

  # The first two bytes of a compressed term in the external term format.
  @etf_version 131
  @etf_compressed 80

  @doc """
  Writes the state of a session as a signed snapshot. See `Rete.Session.dump/2`.
  """
  @spec dump(State.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def dump(%State{} = state, secret) do
    check_secret!(secret, :dump)

    state = %State{state | listeners: []}

    # Only the rules of the network are targeted at their images. A fact is matched by
    # equality, so a changed capture inside one would make a retract of that fact miss after
    # the load.
    # Only a module that the rules still capture counts. A loaded session captures images,
    # so the module of this node does not matter to it.
    network = state.network
    modules = Network.modules(network)

    with {:ok, rule_modules} <- Image.captures(rules(network)),
         {:ok, ruleset_images} <- Image.collect(Enum.filter(modules, &(&1 in rule_modules))),
         state = %State{state | network: target_rules(network, ruleset_images)},
         {:ok, captured} <- Image.captures(state),
         {:ok, images} <- snapshot_images(modules, captured) do
      # `minor_version` is fixed, so a newer OTP default does not write a body that an
      # older node cannot read.
      body =
        :erlang.term_to_binary(%{images: images, state: state}, [:compressed, minor_version: 2])

      # This copies the body once more. `dump/2` returns one binary, so the copy is needed.
      {:ok, :erlang.term_to_binary({:rete_session, @format, mac(@format, body, secret), body})}
    end
  end

  @doc """
  Reads a snapshot back into the state of a session. See `Rete.Session.load/2`.
  """
  @spec load(term(), binary()) :: {:ok, State.t()} | {:error, term()}
  def load(binary, secret) do
    check_secret!(secret, :load)

    with {:ok, format, signature, body} <- unwrap(binary),
         :ok <- verify(format, signature, body, secret),
         :ok <- check_format(format),
         {:ok, %{images: images, state: state}} <- decode(body),
         state = fill_defaults(state),
         # A refused load keeps these images. Another session can need them.
         :ok <- Image.load(images),
         [] <- Image.missing(state, images) do
      {:ok, state}
    else
      [_ | _] = missing -> {:error, {:missing, missing}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The text that `Rete.Session.dump!/2` and `Rete.Session.load!/2` raise, for each reason
  that `dump/2` and `load/2` return.
  """
  @spec message(term()) :: String.t()
  def message({:not_portable, fun}) do
    "It holds #{inspect(fun)}. That is an anonymous function, and it runs only on the " <>
      "build that made it. Use a remote capture such as `&MyApp.fact_type/1`. Look in " <>
      ":fact_type_fn, and in your facts."
  end

  def message({:no_image, _module, _detail} = reason), do: Image.message(reason)

  def message({:no_beam, image}) do
    "The session runs the rules of #{inspect(image)}, and this node has no beam of it. So " <>
      "dump/2 cannot carry those rules. This happens to a session that reached this node " <>
      "by distribution from a node that runs other rules. Dump the session on the node " <>
      "that built or loaded it."
  end

  def message(:invalid), do: "The binary is not a snapshot that Rete.Session.dump/2 wrote."

  def message(:signature) do
    "Its signature does not match the secret. Another key signed it, or someone changed it."
  end

  def message(:undecodable) do
    "Its signature matches the secret, but this node cannot read the body. Another " <>
      "release of OTP or of rete probably wrote it. Load it on a node that runs the " <>
      "release that dumped it."
  end

  def message({:format, format}) do
    "It has format #{format}, and this release of rete reads format #{@format}. Another " <>
      "release of rete wrote it."
  end

  def message({:image, _image, _reason, _otp} = reason), do: Image.message(reason)

  def message({:missing, mfas}) do
    names = Enum.map_join(mfas, ", ", fn {m, f, a} -> Exception.format_mfa(m, f, a) end)
    "The rules call functions that this node does not define: #{names}."
  end

  # An empty key gives an HMAC that anyone can compute, so this refuses it with the rest.
  defp check_secret!(secret, _caller) when is_binary(secret) and byte_size(secret) > 0,
    do: :ok

  defp check_secret!(secret, caller) do
    raise ArgumentError,
          "Rete.Session.#{caller} takes the secret as a non-empty binary, got " <>
            "#{shape(secret)}. Every snapshot is signed with it, and load/2 checks the " <>
            "signature before it decodes the body. Use a random key, such as " <>
            ":crypto.strong_rand_bytes(32). Keep it in your secret store, apart from " <>
            "the snapshots."
  end

  # The kind of value, and never the value. A caller that passes `{:ok, key}` by mistake
  # must not find its key in a log.
  defp shape(<<>>), do: "an empty binary"
  defp shape(nil), do: "nil"
  defp shape(value) when is_atom(value), do: "an atom"
  defp shape(value) when is_tuple(value), do: "a tuple"
  defp shape(value) when is_list(value), do: "a list"
  defp shape(value) when is_integer(value), do: "an integer"
  defp shape(value) when is_map(value), do: "a map"
  defp shape(_value), do: "a value of another type"

  # A field that a release adds, with a default that changes nothing, does not need a new
  # format. A body from an earlier release lacks it, so the load fills it in. The engine
  # then sees one shape, and a read of the field cannot raise. A field with no such default
  # needs a new `@format` instead.
  defp fill_defaults(%State{network: %Network{graph: %BetaGraph{nodes: nodes} = graph}} = state) do
    nodes =
      Map.new(nodes, fn
        {id, %Node.Production{} = node} -> {id, Map.put_new(node, :cache, nil)}
        {id, %Node.Query{} = node} -> {id, Map.put_new(node, :cache, nil)}
        entry -> entry
      end)

    state = state |> Map.put_new(:activation_cache, nil) |> Map.put(:memory, memory(state))
    %State{state | network: %Network{state.network | graph: %BetaGraph{graph | nodes: nodes}}}
  end

  defp memory(%State{memory: memory}), do: Map.put_new(memory, :query_rows, %{})

  # The network without its taxonomy. The taxonomy can hold a `:fact_type_fn`, which is not
  # part of any rule. It keeps its captures, so it always runs the version of the node, as a
  # call to another module does.
  defp rules(%Network{} = network), do: %Network{network | taxonomy: nil}

  # A network built with target images, or a loaded one, calls the images already. So there
  # is nothing to target, and the walk would only copy the network.
  defp target_rules(network, images) when map_size(images) == 0, do: network

  # The rules now run the images, so `built_images` records them. Without the record, a
  # session built without target images would be `latest?/1` after any load.
  defp target_rules(%Network{taxonomy: taxonomy} = network, images) do
    %Network{} = targeted = Image.target(rules(network), images)
    targeted_images = Map.new(images, fn {module, {name, _beam}} -> {module, name} end)

    %Network{
      targeted
      | taxonomy: taxonomy,
        built_images: Map.merge(network.built_images, targeted_images)
    }
  end

  # The snapshot takes each image that the state captures. Its beam comes from a ruleset
  # module of the network, or from the registry. The registry is how a loaded session dumps
  # again. A captured image with no beam is an error, because the snapshot could not load
  # without it.
  defp snapshot_images(modules, captured) do
    offered =
      for module <- modules,
          {:ok, {name, beam}} <- [Image.fetch(module)],
          into: %{},
          do: {name, beam}

    captured
    |> Enum.filter(&Image.image?/1)
    |> Enum.reduce_while({:ok, %{}}, fn image, {:ok, acc} ->
      case Map.get(offered, image) || Image.beam(image) do
        nil -> {:halt, {:error, {:no_beam, image}}}
        beam -> {:cont, {:ok, Map.put(acc, image, beam)}}
      end
    end)
  end

  # The format is signed with the body. Without it, someone without the key could relabel
  # a snapshot of another format as this one, and the body would be read as this format.
  defp mac(format, body, secret),
    do: :crypto.mac(:hmac, :sha256, secret, [<<format::32>>, body])

  # The outer term holds only known atoms, so it takes `:safe`. `dump/2` never compresses it
  # or adds bytes after it, so both are refused before the signature check. `:safe` does not
  # stop decompression, and a small input could inflate to a large term.
  defp unwrap(<<@etf_version, @etf_compressed, _rest::binary>>), do: {:error, :invalid}

  defp unwrap(binary) when is_binary(binary) do
    size = byte_size(binary)

    case :erlang.binary_to_term(binary, [:safe, :used]) do
      {{:rete_session, format, signature, body}, ^size}
      when is_integer(format) and format in 0..0xFFFFFFFF and is_binary(body) ->
        {:ok, format, signature, body}

      _other ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp unwrap(_not_a_binary), do: {:error, :invalid}

  # After the signature, so the format that this reports is one the key holder wrote.
  defp check_format(@format), do: :ok
  defp check_format(format), do: {:error, {:format, format}}

  # `:crypto.hash_equals/2` raises on two lengths that differ, so the size is compared first.
  defp verify(format, signature, body, secret) when is_binary(signature) do
    expected = mac(format, body, secret)

    if byte_size(signature) == byte_size(expected) and :crypto.hash_equals(signature, expected),
      do: :ok,
      else: {:error, :signature}
  end

  defp verify(_format, _signature, _body, _secret), do: {:error, :signature}

  # The signature is good, so a failure here most likely means another release of OTP or of
  # rete. That is why it is `:undecodable` and not `:invalid`. Each entry must be a beam of
  # an image name, because loading reads the beam and must not replace any other module.
  defp decode(body) do
    case :erlang.binary_to_term(body) do
      %{images: images, state: %State{network: %Network{}}} = decoded when is_map(images) ->
        if Enum.all?(images, &beam_of?/1), do: {:ok, decoded}, else: {:error, :undecodable}

      _other ->
        {:error, :undecodable}
    end
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  defp beam_of?({name, beam}) when is_atom(name) and is_binary(beam) do
    case :beam_lib.info(beam) do
      info when is_list(info) -> Image.image_name?(name) and info[:module] == name
      {:error, :beam_lib, _reason} -> false
    end
  end

  defp beam_of?(_entry), do: false
end
