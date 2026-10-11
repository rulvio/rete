defmodule Rete.Image do
  @moduledoc """
  The compiled rule code of a ruleset module, copied into a module named by its content.

  **Internal.** Call `Rete.Session.dump/2` and `Rete.Session.load/2`, and not this module.
  See `docs/design/snapshot.md`.

  A ruleset module compiles its rules into functions of its own, and the network captures
  them as `&MyRules.fun/arity`. A capture is a name, not code. On a node that runs another
  version of `MyRules`, the name finds other code or none. A node holds only one current
  version of a module, so the old `MyRules` cannot load next to the new one.

  So `use Rete.Ruleset` also compiles a copy of those functions into an **image** module,
  `MyRules.Image.M<hash>`. The name starts with the ruleset module, so it shows where an
  image came from. The hash is taken over the copied code. The same code always gives
  the same name, and different code gives a different name. Images of any number of
  versions can thus be loaded on one node together, and loading one twice does nothing.

  The copy starts from every function the network captures. It then follows each local
  call to a helper of the module, private or public, and copies that too. A call that names
  the module itself, `__MODULE__.helper(x)` or `MyRules.helper(x)`, becomes a local call in
  the copy, and so does `super`. A capture of one becomes a capture of the image,
  `&__MODULE__.helper/1`, which stays a remote capture. All of them thus run the code of
  the image. A call to another module stays a remote call, and it runs the version of that
  module that the node has loaded. So does a dynamic call such as `apply(__MODULE__, f, a)`,
  because the copy cannot see which function it names.

  A live session keeps its captures of `MyRules`, so a stack trace names the module you
  wrote. `retarget/2` points them at the image when a session is dumped. The image is a
  copy from the same compile, so the two run the same code.
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

  @typedoc "What `__rete_image__/0` returns. See `define/1`."
  @type offer :: {:ok, t()} | {:unavailable, String.t()} | nil

  @doc false
  # Registered right after `Rete.Ruleset`'s own hook, so the functions that hook defines,
  # such as `get_version/0`, exist when the image copies what the rules call.
  defmacro __before_compile__(env), do: define(env)

  @doc """
  The quoted `__rete_image__/0` of a ruleset module, called from its `@before_compile`.

  This compiles the image module as a side effect. `__rete_image__/0` returns one of three
  values:

    * `{:ok, {image, beam}}` — the image module and its `.beam` binary.
    * `nil` — the module declares no production, so it has no image.
    * `{:unavailable, reason}` — the image did not compile, or `use Rete.Ruleset,
      image: false` turned it off.

  The ruleset module compiles in each case, and runs as it always did. Only
  `Rete.Session.dump/2` refuses a module with no image, and it gives `reason`. A module
  that compiled before images existed must not stop compiling because of them.
  """
  @spec define(Macro.Env.t()) :: Macro.t()
  def define(env) do
    image =
      case seeds(env.module) do
        [] ->
          nil

        seeds ->
          if Module.get_attribute(env.module, :rete_image_enabled, true),
            do: build(env, seeds),
            else: {:unavailable, disabled(env.module)}
      end

    quote do
      @doc false
      def __rete_image__, do: unquote(Macro.escape(image))
    end
  end

  # Any failure here leaves the module without an image, and never stops it compiling.
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
      |> closure(seeds, defined)
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

  # Nested under the ruleset module, so the name shows where an image came from. Two kinds
  # of module take a name under this module instead. One has a name too long to nest,
  # because its `.beam` file name would pass 255 bytes. The other has a plain atom name, such as
  # `:erl_rules`, with no Elixir name to nest under. The hash covers the module name, so
  # that name is still unique.
  defp image_name(module, hash) do
    flat = Module.concat(__MODULE__, "M" <> hash)

    case Atom.to_string(module) do
      "Elixir." <> _rest ->
        nested = Module.split(module) ++ ["Image", "M" <> hash]

        # The code server looks for `<name>.beam` when a module is defined, and a file
        # name holds at most 255 bytes. That limit is the tighter one.
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

  # The image compiles in a process of its own. The compiler tracks the modules that its
  # own processes define. It writes them to `ebin`, checks them for undefined calls and
  # types, and so do coverage and Dialyzer. An image is none of those things. It is data
  # inside `__rete_image__/0`, and it loads from that binary when a snapshot does. So it
  # stays out of `ebin`, and the warnings of the module are not repeated against it.
  #
  # The diagnostics of the compile itself are captured, not printed. The ruleset module
  # already reported every warning in this code. On an error, they become the reason that
  # `Rete.Session.dump/2` gives.
  #
  # Only the file and the line of `env` reach the compile, and not its imports. The clauses
  # are expanded already, so they need none, and an import the module added after a helper
  # would otherwise clash with the copy of that helper.
  defp create(name, env, defs) do
    body = body(defs)
    location = Macro.Env.location(env)

    timeout = Application.get_env(:rete, :image_compile_timeout, @compile_timeout)
    task = Task.async(fn -> compile_alone(name, body, location) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, beam}} ->
        remember(name, beam)
        {:ok, beam}

      {:ok, {:error, detail}} ->
        {:error, detail}

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

    The compiler said:

    #{detail}\
    """
  end

  defp disabled(module) do
    """
    The image of #{inspect(module)} is turned off with `use Rete.Ruleset, image: false`, \
    so a session built from it cannot be dumped. Remove the option to dump it.\
    """
  end

  # `@moduledoc false` keeps an image out of docs, if anything ever asks it for them.
  #
  # Kernel is narrowed to the three macros the body itself needs. A helper of the module may
  # share a name with a function of Kernel, and the full import would then clash with it.
  #
  # `@rete_image` is kept in the beam. It marks the module as an image for `image?/1`, and
  # it records the OTP release that compiled it for the error of `load/1`. A beam can be
  # read without a load, and a snapshot can carry a beam that another release compiled.
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
      case Function.info(fun, :module) do
        {:module, ^module} -> [{fun_name(fun), fun_arity(fun)}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp closure(module, seeds, defined), do: walk(module, seeds, defined, %{})

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

  # Turns each call that would leave the image for the module itself into a call that stays
  # in the image. A remote call to the module would run the version that the node has
  # loaded. That is the one thing an image exists to prevent.
  #
  # A capture becomes `&__MODULE__.fun/arity`, and not `&fun/arity`. In the image,
  # `__MODULE__` is the image, so the capture stays remote. A local capture is a closure,
  # and `Rete.Session.dump/2` refuses a closure, so a fact that held one could not be dumped
  # a second time. The name of the image is not known yet at this point, because the hash
  # covers these clauses. `__MODULE__` stands in for it.
  #
  # A capture of a function that `defined` does not hold stays as it is. Its inner call is
  # marked, so the clause for a remote call does not turn it into a local call. A later
  # hook can define `fun/1` next to a `fun/0` that is defined. Without the mark, the
  # capture `&MyRules.fun/1` would become `&fun()/1`, which does not compile.
  #
  # `super` is a local call. Its metadata names the hidden function that holds the
  # overridden clauses, and `Module.definitions_in/1` lists that function. Left alone, it
  # fails to compile, because the image declares nothing overridable.
  #
  # Two more rewrites keep the copy compiling:
  #
  #   * A `quote` expands to calls of `:elixir_quote`. Inside a `def`, the compiler reads a
  #     direct call of `:elixir_quote.unquote/1` as an unquote fragment, and evaluates its
  #     argument outside the function. Through `:erlang.apply/3`, it is a plain call. This
  #     changes nothing the copy does.
  #   * The struct of the module itself becomes a map with `:__struct__`. Expansion already
  #     filled in the fields, and in a pattern the map matches what the struct matched. Left
  #     as a struct, it needs the module that is still compiling the image. An update,
  #     `%Self{s | k: v}`, becomes a map update. Since Elixir 1.20 that is what a struct
  #     update compiles to. An older Elixir also checks that `s` is a `Self`, and the copy
  #     does not. `docs/design/snapshot.md` §6 lists this. The struct of another module
  #     stays as it is. `build!/2` loads that module first.
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
  defp head(call, guards), do: {:when, [], [call, Enum.reduce(Enum.reverse(guards), &when_/2)]}

  defp when_(guard, acc), do: {:when, [], [guard, acc]}

  # 64 bits of SHA-256. A node may hold images of many versions, and two different
  # images that share a name would make the second one silently run the first one's code.
  # The options fix the encoding, so a new OTP default does not rename an image whose code
  # did not change.
  defp hash(module, defs) do
    defs = Enum.map(defs, fn {kind, name, clauses} -> {kind, name, canonical(clauses)} end)
    encoded = :erlang.term_to_binary({module, @format, defs}, [:deterministic, minor_version: 2])

    :sha256
    |> :crypto.hash(encoded)
    |> binary_part(0, 8)
    |> Base.encode16()
  end

  # The clauses of one definition, with only the metadata that changes what the code does.
  # Lines and files go, so moving a rule in its file does not change the image. A line or a
  # file inside the code itself stays, because it is a value the code returns. `Logger`,
  # `dbg` and `__ENV__` expand to such values.
  #
  # `:version` and `:counter` tell apart two variables of one name. `:counter` counts across
  # the whole module, so an edit elsewhere in it shifts every value. It is renumbered here,
  # in the order the values appear in this definition. `:no_parens` stays, because
  # `map.key` and `map.key()` compile to different code.
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
  def retarget(term, images) when map_size(images) == 0, do: term

  def retarget(term, images) do
    exports =
      Map.new(images, fn {module, {_name, beam}} -> {module, MapSet.new(exports(beam))} end)

    map_funs(term, fn fun ->
      with {:module, module} <- Function.info(fun, :module),
           {:ok, {image, _beam}} <- Map.fetch(images, module),
           {name, arity} = fa = {fun_name(fun), fun_arity(fun)},
           true <- MapSet.member?(Map.fetch!(exports, module), fa) do
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
          do: MapSet.put(acc, fun_module(fun)),
          else: throw({__MODULE__, :not_portable, fun})
      end)

    {:ok, modules}
  catch
    {__MODULE__, :not_portable, fun} -> {:error, {:not_portable, fun}}
  end

  @doc """
  The modules that the captures in `term` name.
  """
  @spec modules(term()) :: MapSet.t(module())
  def modules(term), do: reduce_funs(term, MapSet.new(), &MapSet.put(&2, fun_module(&1)))

  @doc """
  Loads every image this node has not loaded yet.

  Returns `{:error, {:image, module, reason, otp}}` for an image that does not load. `otp`
  is the release that compiled that image, read from its beam, or `nil` if the beam does
  not say.
  """
  @spec load([t()]) :: :ok | {:error, term()}
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
  The image that a ruleset module offers.

  Returns `{:ok, image}`, or `{:error, reason}` when the image did not compile or is turned
  off. Returns `:none` for a module with no production, and for a module that is not a
  ruleset module.
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
  Whether `module` is an image.

  An image is named `<Module>.Image.M<hash>` or `Rete.Image.M<hash>`, and its beam holds
  the `@rete_image` attribute. A loaded module with that name and without the attribute is
  not an image. A module that is not loaded here is taken by its name. So `dump/2` can
  report an image that this node has no beam of.
  """
  @spec image?(module()) :: boolean()
  def image?(module) do
    Atom.to_string(module) =~ ~r/\.Image\.M[0-9A-F]{16}$/ and
      case :code.is_loaded(module) do
        {:file, _file} -> Keyword.has_key?(module.module_info(:attributes), :rete_image)
        false -> true
      end
  end

  @doc """
  The `.beam` binary of an image that this node compiled or loaded, or `nil`.

  A session built with `Rete.Session.from_network/1` over the network of a loaded session
  captures images that no ruleset module of this node offers. `Rete.Session.dump/2` reads
  their binaries here, so that session dumps as the loaded one does.
  """
  @spec beam(module()) :: binary() | nil
  def beam(name), do: :persistent_term.get({__MODULE__, name}, nil)

  # Written once for each image, and never changed. An update of `:persistent_term` costs a
  # scan of every process, but a node loads each image only once.
  defp remember(name, beam) do
    if beam(name) == nil, do: :persistent_term.put({__MODULE__, name}, beam)
    :ok
  end

  # Under a lock, so the check and the load are one step. Two first loads of one image
  # would otherwise both load it. The second load makes the running copy old code, and a
  # third one purges that old code and kills any process still inside it.
  #
  # An image that is loaded already needs no lock. A module is loaded only after
  # `:code.load_binary/3` returns, so this check cannot see half a load. Without it, every
  # load of a known version would wait on the one `global_name_server` process.
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
  @spec missing(term(), [t()]) :: [mfa()]
  def missing(term, images) do
    captured = Enum.map(funs(term), &{fun_module(&1), fun_name(&1), fun_arity(&1)})
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

  defp fun_module(fun), do: fun |> Function.info(:module) |> elem(1)
  defp fun_name(fun), do: fun |> Function.info(:name) |> elem(1)
  defp fun_arity(fun), do: fun |> Function.info(:arity) |> elem(1)

  # `Enum` refuses a struct, so these walk a map through `:maps`. The `:__struct__` key
  # comes back with the rest, so the result is still the struct.
  defp map_funs(fun, f) when is_function(fun), do: f.(fun)
  defp map_funs(list, f) when is_list(list), do: map_list(list, f)
  defp map_funs(tuple, f) when is_tuple(tuple), do: map_tuple(tuple, f)

  defp map_funs(map, f) when is_map(map),
    do: map |> :maps.to_list() |> map_list(f) |> :maps.from_list()

  defp map_funs(term, _f), do: term

  # An improper list, such as `[a | b]`, is legal in a term and `Enum` refuses it.
  defp map_list([head | tail], f), do: [map_funs(head, f) | map_list(tail, f)]
  defp map_list([], _f), do: []
  defp map_list(tail, f), do: map_funs(tail, f)

  defp map_tuple(tuple, f),
    do: tuple |> Tuple.to_list() |> map_list(f) |> List.to_tuple()

  defp reduce_funs(fun, acc, f) when is_function(fun), do: f.(fun, acc)
  defp reduce_funs([head | tail], acc, f), do: reduce_funs(tail, reduce_funs(head, acc, f), f)

  defp reduce_funs(tuple, acc, f) when is_tuple(tuple),
    do: reduce_funs(Tuple.to_list(tuple), acc, f)

  defp reduce_funs(map, acc, f) when is_map(map),
    do: :maps.fold(fn k, v, acc -> reduce_funs(v, reduce_funs(k, acc, f), f) end, acc, map)

  defp reduce_funs(_term, acc, _f), do: acc
end
