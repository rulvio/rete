defmodule Rete.Snapshot do
  @moduledoc """
  The binary format behind `Rete.Session.dump/2` and `Rete.Session.load/2`.

  **Internal.** Call the functions of `Rete.Session`, and not this module. This module holds
  the envelope, the signature, the decode, and the choice of images that a snapshot
  carries. `Rete.Image` holds the images themselves. See `docs/design/snapshot.md`.

  A snapshot is two layers:

      {:rete_session, format, signature, body}
      body = term_to_binary(%{images: %{image => beam}, state: state}, [:compressed, minor_version: 2])

  `signature` is an HMAC-SHA256 of the format and the body under the secret key.
  """

  alias Rete.Agenda
  alias Rete.Engine.State
  alias Rete.Image
  alias Rete.Memory
  alias Rete.Network

  # Increase this when a change to the engine's own structs, such as `Rete.Memory` or a
  # network node, means an older snapshot no longer reads correctly. A change to
  # `Rete.Compiler.Negation.marker/2` or `marker_alpha/1` counts too, because a snapshot
  # captures them by name. The test of struct shapes in `snapshot_test.exs` fails until
  # this changes.
  #
  # The envelope and the MAC input stay the same in every format. Only then can an older
  # release read the format of a newer snapshot and return `{:format, n}`.
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

    # A retracted fact can wait in a tombstone until its bucket compacts. A snapshot must
    # not carry a fact that the caller removed.
    state = %State{
      state
      | listeners: [],
        memory: Memory.compact(state.memory),
        agenda: Agenda.compact(state.agenda)
    }

    # Only the network is retargeted. A fact is the data of the caller, and a fact is
    # matched by equality. Changing a capture inside one would make a retract of the same
    # fact miss it after the load, and could merge two facts into one map key.
    rule_modules = state.network |> Network.rule_parts() |> Image.modules()

    with {:ok, ruleset_images} <- ruleset_images(state.network, rule_modules),
         state = %State{state | network: Image.retarget(state.network, ruleset_images)},
         {:ok, captured} <- Image.captures(state),
         {:ok, images} <- snapshot_images(state.network, captured) do
      # `minor_version` is fixed, so a newer OTP default does not write a body that an
      # older node cannot read.
      body =
        :erlang.term_to_binary(%{images: images, state: state}, [:compressed, minor_version: 2])

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
         # A refused load keeps these images. Another session can need them.
         :ok <- Image.load(Map.to_list(images)),
         [] <- Image.missing(state, Map.to_list(images)) do
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

  def message({:no_image, _module, reason}), do: reason

  def message({:no_beam, image}) do
    "The session runs the rules of #{inspect(image)}, and this node has no beam of it. So " <>
      "dump/2 cannot carry those rules. This happens to a session that reached this node " <>
      "by distribution from a node that loaded a snapshot. Load the " <>
      "snapshot on this node with load/2, and dump the session that it returns."
  end

  def message(:invalid), do: "The binary is not a snapshot that Rete.Session.dump/2 wrote."

  def message(:signature) do
    "Its signature does not match the secret. Another key signed it, or someone changed it."
  end

  def message(:undecodable) do
    "Its signature matches the secret, but this node cannot read the body. A newer " <>
      "release of OTP or of rete probably wrote it. Load it on a node that runs that " <>
      "release."
  end

  def message({:format, format}) do
    "It has format #{format}, and this release of rete reads format #{@format}. Another " <>
      "release of rete wrote it."
  end

  def message({:image, image, reason, otp}) do
    "The image #{inspect(image)} did not load, with the reason #{inspect(reason)}." <>
      otp_hint(otp)
  end

  def message({:missing, mfas}) do
    names = Enum.map_join(mfas, ", ", fn {m, f, a} -> Exception.format_mfa(m, f, a) end)
    "The rules call functions that this node does not define: #{names}."
  end

  # Only a difference in release can explain a failed load this way.
  defp otp_hint(otp) when is_binary(otp) do
    case System.otp_release() do
      ^otp ->
        ""

      here ->
        " OTP #{otp} compiled it, and this node runs OTP #{here}. A beam from a newer OTP " <>
          "may not load on an older one."
    end
  end

  defp otp_hint(_otp), do: ""

  # An empty key gives an HMAC that anyone can compute, so it is refused with the rest.
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

  # Modules a node cannot load, or that compiled before images existed, have no image.
  # `Rete.Image.retarget/2` then leaves their captures alone, and `load/2` checks them.
  #
  # A module whose image did not compile still runs its rules. It only cannot be dumped,
  # and the reason it carries says why.
  #
  # Only a module that the network still captures counts. A loaded session names its
  # ruleset modules, but it captures their images. The module of this node may be another
  # version, and whether it has an image does not matter to that session.
  defp ruleset_images(network, captured) do
    network
    |> Network.modules()
    |> Enum.filter(&MapSet.member?(captured, &1))
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      case Image.fetch(module) do
        {:ok, image} -> {:cont, {:ok, Map.put(acc, module, image)}}
        :none -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:no_image, module, reason}}}
      end
    end)
  end

  # An image that a ruleset module of this node offers, or one that a loaded snapshot
  # brought. The second kind is how a loaded session, or a session built over its network,
  # dumps again. A snapshot without the code of a rule cannot load where that code is
  # missing, so a captured image with no beam is an error here, and not later.
  defp snapshot_images(network, captured) do
    offered = offered_images(network)

    captured
    |> Enum.filter(&Image.image?/1)
    |> Enum.reduce_while({:ok, %{}}, fn image, {:ok, acc} ->
      case Map.get(offered, image) || Image.beam(image) do
        nil -> {:halt, {:error, {:no_beam, image}}}
        beam -> {:cont, {:ok, Map.put(acc, image, beam)}}
      end
    end)
  end

  # Every image that a ruleset module of the network offers, by image module. A module
  # whose image did not compile offers none. This includes a module that the network does
  # not capture, because a session can capture an image of the same code without it.
  defp offered_images(network) do
    for module <- Network.modules(network),
        {:ok, {name, beam}} <- [Image.fetch(module)],
        into: %{},
        do: {name, beam}
  end

  # The format is signed with the body. Without it, someone without the key could relabel
  # a snapshot of another format as this one, and the body would be read as this format.
  defp mac(format, body, secret),
    do: :crypto.mac(:hmac, :sha256, secret, [<<format::32>>, body])

  # The outer term holds no atom a node lacks, so `:safe` applies to it. The body cannot
  # take `:safe`, because it names image modules the node has not seen.
  #
  # `dump/2` never compresses the outer term, so a compressed one is refused before it is
  # decoded. `:safe` does not stop decompression, so a small input could otherwise inflate
  # to a term many times its size before the signature check runs.
  #
  # `:used` gives the bytes the term took. A binary with bytes after the term is not one
  # that `dump/2` wrote, so it is refused too.
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

  # `:crypto.hash_equals/2` raises on two lengths that differ, so the size is compared
  # first. A signature that is not even a binary is a wrong one too.
  defp verify(format, signature, body, secret) when is_binary(signature) do
    expected = mac(format, body, secret)

    if byte_size(signature) == byte_size(expected) and :crypto.hash_equals(signature, expected),
      do: :ok,
      else: {:error, :signature}
  end

  defp verify(_format, _signature, _body, _secret), do: {:error, :signature}

  # The signature is good, so a holder of the key wrote this body. If it does not decode,
  # or has the wrong shape, the cause is most likely another release of OTP or of rete. A
  # format that someone forgot to increase looks the same. So this error is not
  # `:invalid`, which says that the binary is not a snapshot at all.
  #
  # Each image must be a beam of the module it is filed under. Loading and the check for
  # missing functions read the beam, and they would crash on anything else.
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
      info when is_list(info) -> Keyword.get(info, :module) == name
      {:error, :beam_lib, _reason} -> false
    end
  end

  defp beam_of?(_entry), do: false
end
