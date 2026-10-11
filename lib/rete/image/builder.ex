defmodule Rete.Image.Builder do
  @moduledoc """
  Builds the image of a ruleset module while that module compiles.

  **Internal.** `use Rete.Ruleset` registers this module as a `@before_compile` hook. It
  copies the functions that the rules reach into the image module, and defines
  `__rete_image__/0`. `Rete.Image` holds the runtime half. See `docs/design/snapshot.md` §2.
  """

  alias Rete.Image

  # Increase this when a change to code generation changes what a copied function means.
  # Two builds of one ruleset then get two images, instead of sharing one name. The hash
  # covers it, so a change renames every image.
  @hash_version 1

  # A blocked image compile must leave the module without an image, and not hang the build.
  # Two minutes gives a large ruleset room. `:image_compile_timeout` in the `:rete`
  # application environment changes it.
  @compile_timeout :timer.minutes(2)

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
    case guard(fn -> build!(env, seeds) end) do
      {:ok, image} -> {:ok, image}
      {:error, detail} -> {:unavailable, unavailable(env.module, detail)}
    end
  end

  defp build!(env, seeds) do
    defined = env.module |> Module.definitions_in() |> MapSet.new()

    defs = walk(env.module, seeds, defined, %{})

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
    flat = Module.concat(Image, "M" <> hash)

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
    case Image.beam(name) do
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
        Image.remember(name, beam)
        {:ok, beam}

      {:ok, error} ->
        error

      {:exit, reason} ->
        {:error, "the image compile exited: #{inspect(reason)}"}

      nil ->
        {:error, "the image did not compile in #{timeout} ms"}
    end
  end

  # Never raises, because the task is linked to the compile of the ruleset module.
  defp compile_alone(name, body, location) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        guard(fn ->
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
    rete could not compile the image of #{inspect(module)}. The module itself compiled. \
    A build with images, the default, raises for it. `images: false` builds it, for tests \
    only.

    The image is a copy of the functions that the rules compile to, and of the helpers \
    they call. A session runs it, and a snapshot carries it. See docs/design/snapshot.md.

    The usual cause is a helper that a `@before_compile` hook defines after the hook of \
    `use Rete.Ruleset`. Hooks run in the order they are registered, and rete builds the \
    image in its own hook. Put `use Rete.Ruleset` after the `use` that defines the helper. \
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
    |> Image.funs()
    |> Enum.flat_map(fn fun ->
      case Image.mfa(fun) do
        {^module, name, arity} -> [{name, arity}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # `seen` maps each `{name, arity}` to its definition, so each one is read once. It is a
  # plain map, because Dialyzer loses the opaque type of a `MapSet` through this recursion.
  # Sorted, so the hash does not depend on the order of the walk.
  defp walk(_module, [], _defined, seen), do: seen |> Enum.sort() |> Enum.map(&elem(&1, 1))

  defp walk(module, [fa | rest], defined, seen) when is_map_key(seen, fa),
    do: walk(module, rest, defined, seen)

  defp walk(module, [fa | rest], defined, seen) do
    {_kind, _name, clauses} = def = definition(module, fa, defined)
    walk(module, local_calls(clauses, defined) ++ rest, defined, Map.put(seen, fa, def))
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

    encoded =
      :erlang.term_to_binary({module, @hash_version, defs}, [:deterministic, minor_version: 2])

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

  @doc false
  # Runs a step of the image compile, and returns its result. A raise, a throw or an exit
  # becomes `{:error, message}`. One that escaped would stop the compile of the ruleset
  # module, and an image must never do that. Public so that a test can reach each kind of
  # failure. No ruleset causes a throw or an exit here.
  @spec guard((-> {:ok, term()} | {:error, String.t()})) :: {:ok, term()} | {:error, String.t()}
  def guard(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end
end
