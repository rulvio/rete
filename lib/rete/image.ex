defmodule Rete.Image do
  @moduledoc """
  The compiled rule code of a ruleset module, copied into a module named by its content.

  **Internal.** Call `Rete.Session.dump/2` and `Rete.Session.load/2`, and not this module.

  The network captures the rule functions of a ruleset module as `&MyRules.fun/arity`. A
  capture is a name, not code, and a node holds one version of a module. So
  `use Rete.Ruleset` also copies those functions into an **image** module,
  `MyRules.Image.M<hash>`. The hash covers the copied code, so images of many versions
  load on one node together.

  The copy follows each call from a rule to a helper of the module, and runs that helper in
  the image. `Rete.Image.Builder` makes the copy at compile time. This module holds the
  runtime half. `target/2` points the productions at the image when a network is built,
  and the network at the image when a session is dumped. See `docs/design/snapshot.md` §2.

  An image stays loaded, with its beam in `:persistent_term`, for the life of the node.
  """

  @typedoc "An image module and its `.beam` binary."
  @type t :: {module(), binary()}

  @typedoc "The image of each ruleset module, by ruleset module."
  @type by_module :: %{module() => t()}

  @typedoc "The `.beam` binary of each image, by image name."
  @type beams :: %{module() => binary()}

  @doc """
  Points every capture of a ruleset module at its image.

  Takes the images by ruleset module. A module with no image keeps its captures, so the
  check on load decides whether the target node has them.

  A capture of a function that the image does not hold stays a capture of the module. No
  rule reaches that function, so the image did not copy it.
  """
  @spec target(term(), by_module()) :: term()
  def target(term, by_module) do
    targets =
      Map.new(by_module, fn {module, {image, beam}} ->
        {module, {image, MapSet.new(exports(beam))}}
      end)

    point = fn fun ->
      {module, name, arity} = mfa(fun)

      with {:ok, {image, exported}} <- Map.fetch(targets, module),
           true <- MapSet.member?(exported, {name, arity}) do
        Function.capture(image, name, arity)
      else
        _ -> fun
      end
    end

    map_funs(term, point)
  end

  @doc """
  The modules that the captures in `term` name, or the first function that is not a remote
  capture, as an error.

  One walk answers both, because a dump needs both and the state can be large. A closure
  refers to one exact build of the module that made it. Another node, or another build,
  cannot run it.
  """
  @spec captures(term()) :: {:ok, MapSet.t(module())} | {:error, {:not_portable, function()}}
  def captures(term) do
    modules =
      reduce_funs(term, MapSet.new(), fn fun, acc ->
        if Function.info(fun, :type) == {:type, :external},
          do: MapSet.put(acc, elem(mfa(fun), 0)),
          else: throw({__MODULE__, :not_portable, fun})
      end)

    {:ok, modules}
  catch
    {__MODULE__, :not_portable, fun} -> {:error, {:not_portable, fun}}
  end

  @doc """
  Loads every image this node has not loaded yet.

  Returns `{:error, {:image, image, reason, otp}}` for an image that does not load. `otp`
  comes from `otp/1`. `message/1` gives its text.
  """
  @spec load(beams()) :: :ok | {:error, {:image, module(), term(), String.t() | nil}}
  def load(beams) do
    Enum.reduce_while(beams, :ok, fn {name, beam}, :ok ->
      case ensure(name, beam) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:image, name, reason, otp(beam)}}}
      end
    end)
  end

  @doc """
  The text of the error that `load/1` or `fetch/1` returns.
  """
  @spec message({:image, module(), term(), String.t() | nil} | {:no_image, module(), String.t()}) ::
          String.t()
  def message({:no_image, module, detail}) do
    """
    rete could not compile the image of #{inspect(module)}. The module itself compiled. \
    A session built with `target_images: true` runs the image, and a snapshot carries it. \
    A session built without target images calls the module, and does not need the image \
    until it is dumped.

    The usual cause is a helper that a `@before_compile` hook defines after the hook of \
    `use Rete.Ruleset`. Hooks run in the order they are registered, and rete builds the \
    image in its own hook. Put `use Rete.Ruleset` after the `use` that defines the helper. \
    For any other cause, please report it. See docs/design/snapshot.md.

    The cause:

    #{detail}\
    """
  end

  def message({:image, image, reason, otp}) do
    "The image #{inspect(image)} did not load, with the reason #{inspect(reason)}." <>
      otp_hint(otp)
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

  @doc """
  The OTP release that compiled an image, read from its beam without a load, or `nil`.
  """
  @spec otp(binary()) :: String.t() | nil
  def otp(beam) do
    with {:ok, {_name, [attributes: attributes]}} <- :beam_lib.chunks(beam, [:attributes]),
         [%{otp: otp}] <- Keyword.get(attributes, :rete_image) do
      otp
    else
      _ -> nil
    end
  end

  @doc """
  The image that a ruleset module offers, as `{:ok, image}`.

  Returns `{:error, {:no_image, module, detail}}` when the image did not compile, and
  `:none` when the module has no production or is not a ruleset module. `message/1` gives
  the text of the error.
  """
  @spec fetch(module()) :: {:ok, t()} | {:error, {:no_image, module(), String.t()}} | :none
  def fetch(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__rete_image__, 0) do
      case module.__rete_image__() do
        {:ok, image} -> {:ok, image}
        {:no_image, detail} -> {:error, {:no_image, module, detail}}
        nil -> :none
      end
    else
      :none
    end
  end

  @doc """
  The name of the image that a ruleset module offers, or `nil` when `fetch/1` gives no
  image.
  """
  @spec name(module()) :: module() | nil
  def name(module) do
    case fetch(module) do
      {:ok, {name, _beam}} -> name
      _no_image -> nil
    end
  end

  @doc """
  Whether `module` is an image: named as `image_name?/1` accepts, and marked by
  `@rete_image` if it is loaded.

  A module that is not loaded is taken by its name, so a dump can report its missing beam.
  """
  @spec image?(module()) :: boolean()
  def image?(module) do
    image_name?(module) and
      case :code.is_loaded(module) do
        {:file, _file} -> Keyword.has_key?(module.module_info(:attributes), :rete_image)
        false -> true
      end
  end

  @doc """
  Whether `name` has the form of an image name, `<Module>.Image.M<hash>` or
  `Rete.Image.M<hash>`.
  """
  @spec image_name?(atom()) :: boolean()
  def image_name?(name) when is_atom(name),
    do: Atom.to_string(name) =~ ~r/\.Image\.M[0-9A-F]{16}$/

  @doc """
  The `.beam` binary of an image that this node compiled or loaded, or `nil`.

  `Rete.Snapshot` reads it for an image that no ruleset module of this node offers, such as
  one that a loaded session captures, or one from before an upgrade.
  """
  @spec beam(module()) :: binary() | nil
  def beam(name), do: :persistent_term.get({__MODULE__, name}, nil)

  @doc false
  # Written once for each image, and never changed. An update of `:persistent_term` costs a
  # scan of every process, but a node writes each image only once. `Rete.Image.Builder`
  # writes it too.
  def remember(name, beam) do
    if beam(name) == nil, do: :persistent_term.put({__MODULE__, name}, beam)
    :ok
  end

  # No lock. Two first loads of one image can race, and the second makes the first copy old
  # code. A third then gets `:not_purged`, which means the image is loaded. The code is the
  # same in every copy, and rete never purges an image, so no process dies.
  defp ensure(name, beam) do
    loaded =
      if :code.is_loaded(name) do
        :ok
      else
        case :code.load_binary(name, ~c"#{name}.beam", beam) do
          {:module, ^name} -> :ok
          {:error, :not_purged} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    with :ok <- loaded, do: remember(name, beam)
  end

  @doc """
  The remote functions that `term` and `beams` need, and this node lacks.

  `term` contributes every capture it holds. Each image contributes every remote call in
  its code. An empty list means every one of them resolves here. It does not mean they
  behave as they did on the node that dumped the session.
  """
  @spec missing(term(), beams()) :: [mfa()]
  def missing(term, beams) do
    captured = Enum.map(funs(term), &mfa/1)
    imported = Enum.flat_map(beams, fn {_name, beam} -> imports(beam) end)

    (captured ++ imported)
    |> Enum.uniq()
    |> Enum.reject(fn {m, f, a} -> Code.ensure_loaded?(m) and function_exported?(m, f, a) end)
    |> Enum.sort()
  end

  defp exports(beam) do
    {:ok, {_name, [exports: exports]}} = :beam_lib.chunks(beam, [:exports])
    exports
  end

  defp imports(beam) do
    {:ok, {_name, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end

  @doc false
  def funs(term), do: term |> reduce_funs(MapSet.new(), &MapSet.put(&2, &1)) |> MapSet.to_list()

  @doc false
  # Three keys and not `Function.info/1`, which also copies the environment of a closure.
  def mfa(fun) do
    {:module, module} = Function.info(fun, :module)
    {:name, name} = Function.info(fun, :name)
    {:arity, arity} = Function.info(fun, :arity)
    {module, name, arity}
  end

  # `Enum` refuses a struct, so these walk a map through `:maps`. `map_funs` maps only the
  # values, in place, so a struct keeps its `:__struct__` key. No network holds a function
  # as a map key, and `captures/1` still reads the keys.
  defp map_funs(fun, f) when is_function(fun), do: f.(fun)
  defp map_funs([head | tail], f), do: [map_funs(head, f) | map_funs(tail, f)]

  defp map_funs(tuple, f) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> map_funs(f) |> List.to_tuple()

  defp map_funs(map, f) when is_map(map),
    do: :maps.map(fn _key, value -> map_funs(value, f) end, map)

  defp map_funs(term, _f), do: term

  defp reduce_funs(fun, acc, f) when is_function(fun), do: f.(fun, acc)
  defp reduce_funs([head | tail], acc, f), do: reduce_funs(tail, reduce_funs(head, acc, f), f)

  defp reduce_funs(tuple, acc, f) when is_tuple(tuple),
    do: reduce_funs(Tuple.to_list(tuple), acc, f)

  defp reduce_funs(map, acc, f) when is_map(map),
    do: :maps.fold(fn k, v, acc -> reduce_funs(v, reduce_funs(k, acc, f), f) end, acc, map)

  defp reduce_funs(_term, acc, _f), do: acc
end
