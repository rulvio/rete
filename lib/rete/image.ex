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
  the image. `retarget/2` points the network at the image when a session is dumped. See
  `docs/design/snapshot.md` §2.
  """

  # Increase this when a change to code generation changes what a copied function means.
  # Two builds of one ruleset then get two images, instead of sharing one name.
  @format 1

  # A blocked image compile must leave the module without an image, and not hang the build.
  # Two minutes gives a large ruleset room. `:image_compile_timeout` in the `:rete`
  # application environment changes it.
  @compile_timeout :timer.minutes(2)

  alias Rete.Image.Guard

  @typedoc "An image module and its `.beam` binary."
  @type t :: {module(), binary()}

  @doc false
  # Registered right after `Rete.Ruleset`'s own hook, so the functions that hook defines,
  # such as `get_version/0`, exist when the image copies what the rules call.
  #
  # Compiles the image as a side effect, and defines `__rete_image__/0`. Its three values
  # are in `docs/design/snapshot.md` §2.
  defmacro __before_compile__(env) do
    image =
      case seeds(env.module) do
        [] -> nil
        seeds -> build(env, seeds)
      end

    quote do
      @doc false
      def __rete_image__, do: unquote(Macro.escape(image))
    end
  end

  # A failure leaves the module without an image, and only a dump refuses it.
  defp build(env, seeds) do
    case Guard.run(fn -> build!(env, seeds) end) do
      {:ok, image} -> {:ok, image}
      {:error, detail} -> {:unavailable, unavailable(env.module, detail)}
    end
  end

  defp build!(env, seeds) do
    defined = env.module |> Module.definitions_in() |> MapSet.new()

    defs =
      env.module
      |> walk(seeds, defined, %{})
      |> Enum.sort()
      |> Enum.map(&definition(env.module, &1, defined))

    name = image_name(env.module, hash(env.module, defs))
    load_structs(env.module, defs)

    with {:ok, beam} <- image_beam(name, env, defs), do: {:ok, {name, beam}}
  end

  # The image compiles in a process of its own, and a struct literal needs its module loaded
  # there. That process cannot wait for a module that the compiler has not finished, so
  # this process waits first. The ruleset module already needed every one of these
  # structs, so this waits for nothing new.
  defp load_structs(module, defs) do
    ast = for {_kind, _name, clauses} <- defs, clause <- clauses, do: clause_ast(clause)

    {_ast, structs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:%, _, [struct, _map]} = node, acc when is_atom(struct) and struct != module ->
          {node, MapSet.put(acc, struct)}

        node, acc ->
          {node, acc}
      end)

    Enum.each(structs, &Code.ensure_compiled/1)
  end

  # Nested under the ruleset module, so a stack trace shows where an image came from. A plain
  # atom module, such as `:erl_rules`, has no Elixir name to nest under. It takes a name
  # under `Rete.Image`, and the hash covers the module name, so that name is unique.
  defp image_name(module, hash) do
    flat = Module.concat(__MODULE__, "M" <> hash)

    case Atom.to_string(module) do
      "Elixir." <> _rest ->
        nested = Module.split(module) ++ ["Image", "M" <> hash]

        # The code server looks for `<name>.beam`, and a file name holds at most 255 bytes.
        # A longer name takes the flat form too.
        if byte_size("Elixir." <> Enum.join(nested, ".") <> ".beam") <= 255,
          do: Module.concat(nested),
          else: flat

      _plain_atom ->
        flat
    end
  end

  # One VM compiles an image once. Mix recompiles a module whose source did not change when
  # a dependency of it did, and the test suite compiles one source again. The registry then
  # has the beam already, and compiling it again would replace a loaded module.
  defp image_beam(name, env, defs) do
    case beam(name) do
      nil -> create(name, env, defs)
      beam -> {:ok, beam}
    end
  end

  # In a process of its own, so the compiler does not track the image. An image is data in
  # `__rete_image__/0`, and it must stay out of `ebin`, coverage and Dialyzer. Diagnostics
  # are captured, because the ruleset module already reported them. No imports reach the
  # compile. The clauses are expanded, and a late import would clash with a copied helper.
  defp create(name, env, defs) do
    body = body(defs)
    location = Macro.Env.location(env)

    timeout = Application.get_env(:rete, :image_compile_timeout, @compile_timeout)
    task = Task.async(fn -> compile_alone(name, body, location) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, beam}} ->
        remember(name, beam)
        {:ok, beam}

      {:ok, error} ->
        error

      nil ->
        {:error, "the image did not compile in #{timeout} ms"}
    end
  end

  # Never raises, because the task is linked to the compile of the ruleset module.
  defp compile_alone(name, body, location) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        Guard.run(fn ->
          {:module, ^name, beam, _} = Module.create(name, body, location)
          {:ok, beam}
        end)
      end)

    case result do
      {:ok, beam} ->
        {:ok, beam}

      {:error, message} ->
        errors = for %{severity: :error, message: m} <- diagnostics, do: m
        {:error, Enum.join(errors ++ [message], "\n")}
    end
  end

  defp unavailable(module, detail) do
    """
    rete could not compile the image of #{inspect(module)}, so a session built from it \
    cannot be dumped. The module itself compiled, and its rules run.

    The image is a copy of the functions that the rules compile to, and of the helpers \
    they call. A snapshot carries it. See docs/design/snapshot.md.

    The usual cause is a helper that a `@before_compile` hook defines after the hook of \
    `use Rete.Ruleset`. Hooks run in the order they are registered, and the image is built \
    in the hook of rete. Put `use Rete.Ruleset` after the `use` that defines the helper. \
    For any other cause, please report it.

    The cause:

    #{detail}\
    """
  end

  # Kernel is narrowed, because a helper can share a name with a function of Kernel.
  # `@rete_image` stays in the beam. It marks an image for `image?/1`, and it records the
  # OTP release for `otp/1`, which reads a beam without a load.
  defp body(defs) do
    header =
      quote do
        import Kernel, only: [def: 2, defp: 2, @: 1]
        @moduledoc false
        Module.register_attribute(__MODULE__, :rete_image, persist: true)
        @rete_image %{otp: unquote(System.otp_release())}
      end

    {:__block__, [], [header | Enum.flat_map(defs, &def_ast/1)]}
  end

  # Every `{name, arity}` of the module the escaped productions capture.
  defp seeds(module) do
    module
    |> Module.get_attribute(:rule_data, [])
    |> funs()
    |> Enum.flat_map(fn fun ->
      case mfa(fun) do
        {^module, name, arity} -> [{name, arity}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # `seen` is a plain map. Dialyzer loses the opaque type of a `MapSet` through this
  # recursion.
  defp walk(_module, [], _defined, seen), do: Map.keys(seen)

  defp walk(module, [fa | rest], defined, seen) when is_map_key(seen, fa),
    do: walk(module, rest, defined, seen)

  defp walk(module, [fa | rest], defined, seen) do
    {_kind, _name, clauses} = definition(module, fa, defined)
    walk(module, local_calls(clauses, defined) ++ rest, defined, Map.put(seen, fa, true))
  end

  # Expanded AST, so an import is already a remote call and a macro is already gone. What
  # is left as `{name, meta, args}` with a defined `{name, arity}` is a local call. A capture
  # of the image itself, which `localize/3` writes, counts as one too.
  defp local_calls(clauses, defined) do
    clauses = Enum.map(clauses, &clause_ast/1)

    {_ast, calls} =
      Macro.prewalk(clauses, [], fn
        {:&, _, [{:/, _, [{{:., _, [{:__MODULE__, _, _}, name]}, _, []}, arity]}]} = node, acc
        when is_atom(name) and is_integer(arity) ->
          {node, local(defined, {name, arity}, acc)}

        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, local(defined, {name, arity}, acc)}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, local(defined, {name, length(args)}, acc)}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp local(defined, fa, acc), do: if(MapSet.member?(defined, fa), do: [fa | acc], else: acc)

  # A clause is a 4-tuple, which is not AST, so a walk would not descend into it.
  defp clause_ast({_meta, args, guards, body}), do: [args, guards, body]

  # The one place that reads a definition, so the closure, the hash and the copy all see the
  # same localized clauses.
  defp definition(module, {name, arity}, defined) do
    {:v1, kind, _meta, clauses} = Module.get_definition(module, {name, arity})
    {kind, name, Enum.map(clauses, &localize(&1, module, defined))}
  end

  # Keeps every call to the module itself inside the image. See `docs/design/snapshot.md` §2.
  #
  #   * A capture becomes `&__MODULE__.fun/arity`. The image name is not known yet, and a
  #     local capture would be a closure, which a dump refuses.
  #   * A capture of a function not yet defined stays, and its inner call gets `rete_kept`.
  #     Without the mark, `&MyRules.fun/1` beside a `fun/0` would become `&fun()/1`.
  #   * `super` becomes a call to the hidden function that holds the overridden clauses.
  #   * A call that `quote` expands to goes through `:erlang.apply/3`. A direct call of
  #     `:elixir_quote.unquote/1` in a `def` reads as an unquote fragment.
  #   * The struct of the module becomes a map, because the module is still compiling. On
  #     Elixir before 1.20, this skips one check of a struct update. See §6.
  defp localize({meta, args, guards, body}, module, defined) do
    [args, guards, body] =
      Macro.prewalk([args, guards, body], fn
        {:&, m, [{:/, m2, [{{:., m3, [^module, fun]}, m4, []}, arity]}]}
        when is_atom(fun) and is_integer(arity) ->
          if MapSet.member?(defined, {fun, arity}),
            do: {:&, m, [{:/, m2, [{{:., m3, [{:__MODULE__, [], nil}, fun]}, m4, []}, arity]}]},
            else:
              {:&, m, [{:/, m2, [{{:., m3, [module, fun]}, [rete_kept: true] ++ m4, []}, arity]}]}

        {{:., _, [^module, fun]}, m, call_args} = node when is_atom(fun) and is_list(call_args) ->
          if MapSet.member?(defined, {fun, length(call_args)}) and
               not Keyword.has_key?(m, :rete_kept),
             do: {fun, m, call_args},
             else: node

        {:super, m, call_args} = node when is_list(call_args) ->
          case Keyword.fetch(m, :super) do
            {:ok, {_kind, hidden}} -> {hidden, Keyword.delete(m, :super), call_args}
            :error -> node
          end

        {{:., _, [:elixir_quote, fun]}, m, call_args} when is_atom(fun) and is_list(call_args) ->
          {{:., m, [:erlang, :apply]}, m, [:elixir_quote, fun, call_args]}

        {:%, _, [^module, {:%{}, m, [{:|, _, [_expr, _fields]}] = update}]} ->
          {:%{}, m, update}

        {:%, _, [^module, {:%{}, m, fields}]} when is_list(fields) ->
          {:%{}, m, [{:__struct__, module} | fields]}

        node ->
          node
      end)

    {meta, args, guards, body}
  end

  # A macro is expanded at every call site already, so the closure never needs one. A
  # local call to a `defmacrop` is gone from the AST by the time `local_calls/2` reads it.
  defp def_ast({kind, _name, _clauses}) when kind in [:defmacro, :defmacrop], do: []

  defp def_ast({kind, name, clauses}) do
    Enum.map(clauses, fn {meta, args, guards, body} ->
      {kind, meta, [head({name, meta, args}, guards), [do: body]]}
    end)
  end

  defp head(call, []), do: call

  defp head(call, guards),
    do: {:when, [], [call, Enum.reduce(Enum.reverse(guards), &{:when, [], [&1, &2]})]}

  # 64 bits of SHA-256, because two images that share a name would run one code for both.
  # The options fix the encoding, so a new OTP default does not rename an image.
  defp hash(module, defs) do
    defs = Enum.map(defs, fn {kind, name, clauses} -> {kind, name, canonical(clauses)} end)
    encoded = :erlang.term_to_binary({module, @format, defs}, [:deterministic, minor_version: 2])

    :sha256
    |> :crypto.hash(encoded)
    |> binary_part(0, 8)
    |> Base.encode16()
  end

  # Only the metadata that changes what the code does. Lines go, so moving a rule keeps the
  # name. `:counter` counts across the module, so it is numbered again in each definition.
  # `:no_parens` stays, because `map.key` and `map.key()` compile differently.
  defp canonical(clauses) do
    ast = Enum.map(clauses, &clause_ast/1)

    {ast, _counters} =
      Macro.prewalk(ast, %{}, fn
        {form, meta, args}, counters when is_list(meta) ->
          {meta, counters} = canonical_meta(meta, counters)
          {{form, meta, args}, counters}

        node, counters ->
          {node, counters}
      end)

    ast
  end

  defp canonical_meta(meta, counters) do
    kept = Keyword.take(meta, [:version, :no_parens])

    case Keyword.fetch(meta, :counter) do
      {:ok, counter} ->
        counters = Map.put_new(counters, counter, map_size(counters))
        {Keyword.put(kept, :counter, Map.fetch!(counters, counter)), counters}

      :error ->
        {kept, counters}
    end
  end

  # --------------------------------------------------------------------------
  # dump and load
  # --------------------------------------------------------------------------

  @doc """
  Points every capture of a ruleset module at its image.

  Takes the images by ruleset module. A module with no image keeps its captures, so the
  check on load decides whether the target node has them.

  A capture of a function that the image does not hold stays a capture of the module. No
  rule reaches that function, so the image did not copy it. A `:fact_type_fn` defined in a
  ruleset module is the usual case. It then runs the version of the node that loads the
  session, as a call to any other module does.
  """
  @spec retarget(term(), %{module() => t()}) :: term()
  def retarget(term, images) do
    targets =
      Map.new(images, fn {module, {image, beam}} ->
        {module, {image, MapSet.new(exports(beam))}}
      end)

    map_funs(term, fn fun ->
      {module, name, arity} = mfa(fun)

      with {:ok, {image, exported}} <- Map.fetch(targets, module),
           true <- MapSet.member?(exported, {name, arity}) do
        Function.capture(image, name, arity)
      else
        _ -> fun
      end
    end)
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

  Returns `{:error, {:image, module, reason, otp}}` for an image that does not load. `otp`
  comes from `otp/1`.
  """
  @spec load(%{module() => binary()}) :: :ok | {:error, term()}
  def load(images) do
    Enum.reduce_while(images, :ok, fn {name, beam}, :ok ->
      case ensure(name, beam) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:image, name, reason, otp(beam)}}}
      end
    end)
  end

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

  Returns `{:error, reason}` when the image did not compile, and `:none` when the module
  has no production or is not a ruleset module.
  """
  @spec fetch(module()) :: {:ok, t()} | {:error, String.t()} | :none
  def fetch(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__rete_image__, 0) do
      case module.__rete_image__() do
        {:ok, image} -> {:ok, image}
        {:unavailable, reason} -> {:error, reason}
        nil -> :none
      end
    else
      :none
    end
  end

  @doc """
  What `fetch/1` returns, with the image name in place of `{name, beam}`. The beam goes
  into the registry that `beam/1` reads.

  A network calls this for each module when it is built. The beam must outlive an upgrade
  of the module, because a dump carries the image that the network was built with.
  """
  @spec register(module()) :: {:ok, module()} | {:error, String.t()} | :none
  def register(module) do
    case fetch(module) do
      {:ok, {name, beam}} ->
        remember(name, beam)
        {:ok, name}

      no_image ->
        no_image
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
  Whether `module` is an image: named `<Module>.Image.M<hash>`, and marked by
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
  The `.beam` binary of an image that this node compiled, loaded, or built a network from,
  or `nil`.

  `Rete.Snapshot` reads it for an image that no ruleset module of this node offers, such as
  one that a loaded session captures, or one from before an upgrade.
  """
  @spec beam(module()) :: binary() | nil
  def beam(name), do: :persistent_term.get({__MODULE__, name}, nil)

  # Written once for each image, and never changed. An update of `:persistent_term` costs a
  # scan of every process, but a node writes each image only once.
  defp remember(name, beam) do
    if beam(name) == nil, do: :persistent_term.put({__MODULE__, name}, beam)
    :ok
  end

  # A first load takes a lock. Two loads of one image would make the running copy old code,
  # and a third would purge it. A loaded image skips the lock, because `:code.is_loaded/1`
  # cannot see half a load, and the lock goes through one `global_name_server` process.
  defp ensure(name, beam) do
    if :code.is_loaded(name) do
      remember(name, beam)
    else
      :global.trans({{__MODULE__, name}, self()}, fn -> ensure_unlocked(name, beam) end, [node()])
    end
  end

  defp ensure_unlocked(name, beam) do
    loaded =
      if :code.is_loaded(name) do
        :ok
      else
        case :code.load_binary(name, ~c"#{name}.beam", beam) do
          {:module, ^name} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    with :ok <- loaded, do: remember(name, beam)
  end

  @doc """
  The remote functions that `term` and `images` need, and this node lacks.

  `term` contributes every capture it holds. Each image contributes every remote call in
  its code. An empty list means every one of them resolves here. It does not mean they
  behave as they did on the node that dumped the session.
  """
  @spec missing(term(), %{module() => binary()}) :: [mfa()]
  def missing(term, images) do
    captured = Enum.map(funs(term), &mfa/1)
    imported = Enum.flat_map(images, fn {_name, beam} -> imports(beam) end)

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

  defp funs(term), do: term |> reduce_funs(MapSet.new(), &MapSet.put(&2, &1)) |> MapSet.to_list()

  # Three keys and not `Function.info/1`, which also copies the environment of a closure.
  defp mfa(fun) do
    {:module, module} = Function.info(fun, :module)
    {:name, name} = Function.info(fun, :name)
    {:arity, arity} = Function.info(fun, :arity)
    {module, name, arity}
  end

  # `Enum` refuses a struct, so these walk a map through `:maps`. The `:__struct__` key
  # comes back with the rest, so the result is still the struct.
  defp map_funs(fun, f) when is_function(fun), do: f.(fun)
  defp map_funs([head | tail], f), do: [map_funs(head, f) | map_funs(tail, f)]

  defp map_funs(tuple, f) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> map_funs(f) |> List.to_tuple()

  defp map_funs(map, f) when is_map(map),
    do: map |> :maps.to_list() |> map_funs(f) |> :maps.from_list()

  defp map_funs(term, _f), do: term

  defp reduce_funs(fun, acc, f) when is_function(fun), do: f.(fun, acc)
  defp reduce_funs([head | tail], acc, f), do: reduce_funs(tail, reduce_funs(head, acc, f), f)

  defp reduce_funs(tuple, acc, f) when is_tuple(tuple),
    do: reduce_funs(Tuple.to_list(tuple), acc, f)

  defp reduce_funs(map, acc, f) when is_map(map),
    do: :maps.fold(fn k, v, acc -> reduce_funs(v, reduce_funs(k, acc, f), f) end, acc, map)

  defp reduce_funs(_term, acc, _f), do: acc
end
