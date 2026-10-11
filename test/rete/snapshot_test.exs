defmodule Rete.SnapshotTest do
  @moduledoc """
  `Rete.Session.dump/2` and `Rete.Session.load/2`.

  The promise is that a loaded session runs the rules it was dumped with. A test of that
  needs two versions of one ruleset module. Each test compiles them from source with its
  own module name, so the tests can run at the same time.
  """

  use ExUnit.Case, async: true

  alias Rete.Listener.Collect
  alias Rete.Session

  @key "rete-snapshot-test"

  @shapes %{
    Taxo => [:ancestors, :descendants, :parents],
    Rete.Activation => [:internal_salience, :node_id, :order, :salience, :token],
    Rete.Agenda => [:buckets],
    Rete.Bucket => [:counts, :dead, :dead_total, :indexed?, :live, :queue],
    Rete.Compiler.BetaGraph => [:backward, :forward, :next_id, :nodes, :shared],
    Rete.Element => [:bindings, :fact],
    Rete.Engine.State => [:agenda, :fired, :listeners, :memory, :network, :order, :queue],
    Rete.IR.Coll => [
      :__ast__,
      :alpha,
      :bind,
      :coll_binding,
      :inert,
      :join_bind,
      :join_filter,
      :new_bind,
      :type
    ],
    Rete.IR.CompoundNegation => [:conditions],
    Rete.IR.Expr => [:__ast__, :arity, :code, :fun, :kind, :name, :share],
    Rete.IR.Fact => [
      :__ast__,
      :alpha,
      :bind,
      :fact_binding,
      :join_bind,
      :join_filter,
      :new_bind,
      :type
    ],
    Rete.IR.Gate => [:args, :code, :gate],
    Rete.IR.Negation => [:condition],
    Rete.IR.Production => [
      :__ast__,
      :bind,
      :hash,
      :head,
      :lhs,
      :module,
      :name,
      :opts,
      :params,
      :rhs,
      :type
    ],
    Rete.IR.Test => [:__ast__, :bind, :expr, :source],
    Rete.Memory => [
      :accum,
      :elements,
      :facts,
      :inserters,
      :insertions,
      :root_seeded?,
      :tokens
    ],
    Rete.Network => [
      :alphas,
      :built_images,
      :graph,
      :productions,
      :queries,
      :reserved_types,
      :taxonomy
    ],
    Rete.Network.Node.Accumulate => [
      :alpha_code,
      :coll_binding,
      :id,
      :join_bind,
      :new_bind,
      :propagates_empty?,
      :type
    ],
    Rete.Network.Node.AccumulateJoin => [
      :alpha_code,
      :coll_binding,
      :filter,
      :filter_code,
      :id,
      :join_bind,
      :new_bind,
      :propagates_empty?,
      :type
    ],
    Rete.Network.Node.Alpha => [:children, :code, :fun, :id, :type],
    Rete.Network.Node.ExprJoin => [
      :alpha_code,
      :fact_binding,
      :filter,
      :filter_code,
      :id,
      :join_bind,
      :new_bind,
      :type
    ],
    Rete.Network.Node.HashJoin => [:alpha_code, :fact_binding, :id, :join_bind, :new_bind, :type],
    Rete.Network.Node.Negation => [:alpha_code, :id, :join_bind, :type],
    Rete.Network.Node.NegationJoin => [:alpha_code, :filter, :filter_code, :id, :join_bind, :type],
    Rete.Network.Node.Production => [
      :bind,
      :generated?,
      :hash,
      :id,
      :internal_salience,
      :module,
      :name,
      :rhs,
      :salience
    ],
    Rete.Network.Node.Query => [:bind, :hash, :head, :id, :module, :name, :params, :rhs],
    Rete.Network.Node.RootJoin => [:alpha_code, :fact_binding, :id, :new_bind, :type],
    Rete.Network.Node.Test => [:code, :fun, :id],
    Rete.Taxonomy => [:alphas, :fact_type_fn, :index, :taxo],
    Rete.Token => [:bindings, :matches]
  }

  # v1 flags an order above 100, through a private helper and a compound negation. v2
  # changes the helper, the threshold and the tag. A loaded v1 session must keep all three.
  defp source(module, version) do
    {limit, tag} = if version == :v1, do: {100, :v1}, else: {1000, :v2}

    """
    defmodule #{inspect(module)} do
      use Rete.Ruleset

      defrule flag({:customer, cid}, {:order, cid, amt} when big?(amt)) do
        {:flagged, cid, #{inspect(tag)}}
      end

      defrule clean({:customer, cid}, {:nand, [{:order, cid, _a}, {:refund, cid}]}) do
        {:clean, cid, #{inspect(tag)}}
      end

      defquery flagged(cid)({:flagged, cid, tag}), do: tag

      defp big?(amt), do: amt > #{limit}
    end
    """
  end

  defp compile(module, version) do
    Code.compile_string(source(module, version))
    module
  end

  # A new deploy of the module: the old version leaves, and its image stays loaded, as it
  # would on a node where a v1 session is still alive.
  defp redeploy(module, version) do
    :code.purge(module)
    :code.delete(module)
    compile(module, version)
  end

  defp v1_session(module) do
    [module]
    |> Session.new()
    |> Session.insert([{:customer, 1}, {:order, 1, 500}, {:customer, 2}])
    |> Session.fire_rules()
  end

  describe "on one node, across a redeploy" do
    test "a loaded session runs the rules it was dumped with" do
      module = compile(Rete.SnapshotTest.Upgrade, :v1)
      snapshot = module |> v1_session() |> Session.dump!(@key)

      redeploy(module, :v2)
      {:ok, loaded} = Session.load(snapshot, @key)
      refute Session.latest?(loaded)

      # v2 declares the query with the same head, so the function v2 defines reaches the
      # v1 query node by its `{module, name}`.
      assert [:v1] == module.flagged(loaded, 1)

      grown = loaded |> Session.insert({:order, 2, 500}) |> Session.fire_rules()

      assert [:v1] == Session.query(grown, {module, :flagged}, cid: 2)
      clean = grown |> Session.facts() |> Enum.filter(&match?({:clean, _, _}, &1))
      assert [{:clean, 1, :v1}, {:clean, 2, :v1}] == Enum.sort(clean)

      fresh =
        [module]
        |> Session.new()
        |> Session.insert([{:customer, 2}, {:order, 2, 500}])
        |> Session.fire_rules()

      assert [] == Session.query(fresh, {module, :flagged}, cid: 2)
    end

    # A v1 session dumped again on a v2 node must carry the v1 image, and not the image
    # that the v2 module offers.
    test "a loaded session dumps again with the image it was loaded with" do
      module = compile(Rete.SnapshotTest.Redump, :v1)
      {:ok, {v1_image, _beam}} = module.__rete_image__()
      snapshot = module |> v1_session() |> Session.dump!(@key)

      redeploy(module, :v2)
      {:ok, {v2_image, _beam}} = module.__rete_image__()
      {:ok, loaded} = Session.load(snapshot, @key)
      redump = Session.dump!(loaded, @key)
      {:ok, again} = Session.load(redump, @key)

      assert v1_image != v2_image
      assert [v1_image] == images_in(redump)
      assert [:v1] == Session.query(again, {module, :flagged}, cid: 1)
    end

    # The v2 module has no image, because a later hook defines its helper. The loaded v1
    # session captures the v1 image, so the v2 module does not matter to it.
    test "a loaded session dumps again when the module of this node has no image" do
      module = compile(Rete.SnapshotTest.RedumpLate, :v1)
      snapshot = module |> v1_session() |> Session.dump!(@key)

      purge(module)
      late_hook_ruleset(Rete.SnapshotTest.RedumpLate, Rete.SnapshotTest.RedumpLateLib)
      assert {:unavailable, _reason} = module.__rete_image__()

      {:ok, loaded} = Session.load(snapshot, @key)
      redump = Session.dump!(loaded, @key)
      assert images_in(snapshot) == images_in(redump)

      assert {:ok, again} = Session.load(redump, @key)
      assert [:v1] == Session.query(again, {module, :flagged}, cid: 1)
    end

    # The docs tell a long-lived application to build sessions from one network. A network
    # taken from a loaded session captures images that no module of this node offers.
    test "a session built over the network of a loaded session dumps with its images" do
      module = compile(Rete.SnapshotTest.FromNetwork, :v1)
      {:ok, {v1_image, _beam}} = module.__rete_image__()
      snapshot = module |> v1_session() |> Session.dump!(@key)

      redeploy(module, :v2)
      {:ok, loaded} = Session.load(snapshot, @key)
      fresh = loaded |> Session.network() |> Session.from_network() |> Session.dump!(@key)

      assert v1_image in images_in(fresh)
    end

    test "a network records the image that each ruleset module offers" do
      module = compile(Rete.SnapshotTest.Recorded, :v1)
      {:ok, {image, _beam}} = module.__rete_image__()

      assert %{module => {:ok, image}} == Session.network(Session.new([module])).built_images
      assert :none == Rete.Image.register(Enum)
      assert nil == Rete.Image.name(Enum)
    end

    # A rule calls `fact_type/1`, so the image exports it. The taxonomy keeps the capture
    # of the module all the same.
    test "the :fact_type_fn of a ruleset module is never pointed at its image" do
      [{module, _beam}] =
        Code.compile_string("""
        defmodule Rete.SnapshotTest.TypeFn do
          use Rete.Ruleset
          defrule tag({:order, cid}), do: {:tagged, cid, fact_type({:order, cid})}
          def fact_type(fact), do: elem(fact, 0)
        end
        """)

      fun = &module.fact_type/1
      network = Session.network(Session.new([module], fact_type_fn: fun))

      assert fun == network.taxonomy.fact_type_fn
    end

    # The session runs the v1 image, so the v2 module does not reach it. A new session
    # picks up v2.
    test "a session built with images keeps its rules across a redeploy" do
      module = compile(Rete.SnapshotTest.Kept, :v1)
      session = v1_session(module)
      assert Session.latest?(session)

      redeploy(module, :v2)
      refute Session.latest?(session)

      grown = session |> Session.insert({:order, 2, 500}) |> Session.fire_rules()
      assert [:v1] == Session.query(grown, {module, :flagged}, cid: 2)

      fresh = v1_session(module)
      assert Session.latest?(fresh)
      assert [] == Session.query(fresh, {module, :flagged}, cid: 1)
    end

    # The session calls the v2 module now. Its dump still carries the image it was built
    # with, so the loaded session runs v1 and does not mix the two versions.
    test "a session built without images dumps the image it was built with" do
      module = compile(Rete.SnapshotTest.NoImages, :v1)
      {:ok, {v1_image, _beam}} = module.__rete_image__()

      session =
        [module]
        |> Session.new(images: false)
        |> Session.insert([{:customer, 1}, {:order, 1, 500}])
        |> Session.fire_rules()

      redeploy(module, :v2)
      refute Session.latest?(session)

      snapshot = Session.dump!(session, @key)
      assert [v1_image] == images_in(snapshot)

      {:ok, loaded} = Session.load(snapshot, @key)
      grown = loaded |> Session.insert([{:customer, 2}, {:order, 2, 500}]) |> Session.fire_rules()
      assert [:v1] == Session.query(grown, {module, :flagged}, cid: 2)
    end
  end

  # Building the image must never stop a ruleset module from compiling.
  describe "rulesets the image must not break" do
    test "a helper from a later @before_compile leaves the module without an image" do
      module = late_hook_ruleset(Rete.SnapshotTest.LateHook, Rete.SnapshotTest.LateLib)
      assert {:unavailable, reason} = module.__rete_image__()
      assert reason =~ "@before_compile"
      assert reason =~ "undefined function big?/1"

      session =
        [module] |> Session.new() |> Session.insert({:order, 1, 5000}) |> Session.fire_rules()

      assert {:flagged, 1, :v2} in Session.facts(session)

      assert {:error, {:no_image, ^module, reason}} = Session.dump(session, @key)
      assert reason =~ "Put `use Rete.Ruleset` after"

      error = assert_raise ArgumentError, fn -> Session.dump!(session, @key) end
      assert error.message =~ "Put `use Rete.Ruleset` after"
    end

    # `late/1` comes from a later hook, so the image keeps its capture as a capture of the
    # module. `late/0` is a local helper, and the copy must not take one for the other.
    test "a capture of a later helper beside a local helper of the same name" do
      source = """
      defmodule Rete.SnapshotTest.CaptureLib do
        defmacro __using__(_opts), do: quote(do: @before_compile(Rete.SnapshotTest.CaptureLib))
        defmacro __before_compile__(_env), do: quote(do: def(late(x), do: x * 2))
      end

      defmodule Rete.SnapshotTest.CaptureLate do
        use Rete.Ruleset
        use Rete.SnapshotTest.CaptureLib
        def late, do: :zero
        def pick, do: &__MODULE__.late/1
        defrule flag({:order, cid, amt}), do: {:flagged, cid, pick().(amt)}
      end
      """

      module = compile_source(source, Rete.SnapshotTest.CaptureLate)

      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:order, 1, 21}) |> Session.fire_rules() |> Session.facts()

      assert {:flagged, 1, 42} in facts
    end

    test "an import that comes after a helper of the same name" do
      # The import is unused, and its warning is not the point here.
      {module, _diagnostics} =
        Code.with_diagnostics(fn ->
          compile_source(
            """
                defmodule Rete.SnapshotTest.LateImport do
              use Rete.Ruleset
              defrule r({:a, x}), do: {:b, trim(x)}
              defp trim(x), do: {:mine, x}
              import String, only: [trim: 1]
            end
            """,
            Rete.SnapshotTest.LateImport
          )
        end)

      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:a, 1}) |> Session.fire_rules() |> Session.facts()
      assert {:b, {:mine, 1}} in facts
    end

    # The nested name holds 253 characters, so it is a legal atom. Its `.beam` file name
    # would hold 258 bytes, and the code server logs an error for a name that long. So the
    # file name limit decides, and the image takes the flat name.
    test "a module name too long to nest under takes an image under Rete.Image" do
      module = Module.concat(Rete.SnapshotTest, String.duplicate("A", 204))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Code.compile_string(helper_source(module, 100, "big?(amt)", ""))
        end)

      assert log == ""

      assert {:ok, {image, _beam}} = module.__rete_image__()
      assert ["Rete", "Image", "M" <> _hash] = Module.split(image)
    end

    # Captured at stderr too, because the image compiles in a process of its own, and a
    # diagnostic from there would not reach `Code.with_diagnostics/2` here.
    test "a warning in rule code is reported once, against the ruleset module" do
      module = Rete.SnapshotTest.Warned

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {_result, diagnostics} =
            Code.with_diagnostics(fn ->
              Code.compile_string("""
              defmodule #{inspect(module)} do
                use Rete.Ruleset
                defrule r({:a, x}), do: {:b, helper(x)}
                def helper(x) do
                  unused = 1
                  x
                end
              end
              """)
            end)

          assert [%{message: message}] = diagnostics
          assert message =~ "unused"
        end)

      refute stderr =~ ".Image.M"
    end

    # One VM compiles an image once. A second compile of the same rules takes the beam from
    # the registry, and does not redefine the loaded image.
    test "the same rules compiled again reuse the image, and redefine nothing" do
      module = compile(Rete.SnapshotTest.Reused, :v1)
      {:ok, {first, _beam}} = module.__rete_image__()
      assert ["Image", "M" <> _hash] = Module.split(first) -- Module.split(module)
      purge(module)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {_result, diagnostics} = Code.with_diagnostics(fn -> compile(module, :v1) end)
          refute Enum.any?(diagnostics, &(&1.message =~ "redefining"))
        end)

      refute stderr =~ "redefining"
      assert {:ok, {^first, _beam}} = module.__rete_image__()

      # A second load of a loaded module makes the running copy old code.
      refute :erlang.check_old_code(first)
    end

    test "a rule that calls get_version/0 of its own module" do
      source = """
      defmodule Rete.SnapshotTest.Versioned do
        use Rete.Ruleset
        defrule r({:a, x}), do: {:b, x, is_integer(get_version())}
      end
      """

      module = compile_source(source, Rete.SnapshotTest.Versioned)

      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:a, 1}) |> Session.fire_rules() |> Session.facts()
      assert {:b, 1, true} in facts
    end

    # The image compiles in a process of its own. The struct modules it names are loaded
    # first, and the loaded session must behave as the live one does, update included.
    test "a rule that builds, matches and updates the struct of another module" do
      source = """
      defmodule Rete.SnapshotTest.Other do
        defstruct a: 1, b: 2
      end

      defmodule Rete.SnapshotTest.UsesOther do
        use Rete.Ruleset
        alias Rete.SnapshotTest.Other
        defrule r({:a, x}), do: {:b, bump(%Other{b: x})}
        def bump(%Other{b: b} = s), do: %Other{s | b: b + 1}
      end
      """

      module = compile_source(source, Rete.SnapshotTest.UsesOther)

      live = [module] |> Session.new() |> Session.insert({:a, 5}) |> Session.fire_rules()
      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      moved = loaded |> Session.insert({:a, 5}) |> Session.fire_rules()

      assert Enum.sort(Session.facts(live)) == Enum.sort(Session.facts(moved))
      assert {:b, %{__struct__: Rete.SnapshotTest.Other, a: 1, b: 6}} in Session.facts(moved)
    end

    # A real `mix compile`. Mix makes a module that the compiler finished available to the
    # processes of the compiler, and not to others. The image compiles in a process of its
    # own, so the ruleset must load the struct for it first. A direct call of the parallel
    # compiler loads each module at once, and does not show this.
    @tag :tmp_dir
    test "a struct module that Mix compiles after the ruleset", %{tmp_dir: dir} do
      root = File.cwd!()

      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule Fixture.MixProject do
        use Mix.Project

        def project do
          [
            app: :fixture,
            version: "0.1.0",
            deps: [
              {:rete, path: #{inspect(root)}},
              {:taxo, path: #{inspect(Path.join(root, "deps/taxo"))}, override: true}
            ]
          ]
        end
      end
      """)

      File.write!(Path.join(dir, "lib/a_rules.ex"), """
      defmodule Fixture.Rules do
        use Rete.Ruleset
        defrule r({:n, x}), do: {:out, f(x)}
        defp f(x), do: %Fixture.Struct{b: x}
      end
      """)

      # The struct must still be compiling when the image of the ruleset compiles. The sleep
      # gives that margin. Without it, the struct always finishes first, and the test passes
      # even with `load_structs/2` removed.
      File.write!(Path.join(dir, "lib/z_struct.ex"), """
      defmodule Fixture.Struct do
        Process.sleep(300)
        defstruct a: 1, b: 2
      end
      """)

      env = [{"MIX_ENV", "dev"}]

      {out, status} =
        System.cmd("mix", ["compile", "--force"], cd: dir, env: env, stderr_to_stdout: true)

      assert status == 0, out

      {out, status} =
        System.cmd(
          "mix",
          [
            "run",
            "--no-compile",
            "-e",
            "{:ok, {image, _}} = Fixture.Rules.__rete_image__(); IO.inspect(image)"
          ],
          cd: dir,
          env: env,
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert out =~ "Fixture.Rules.Image.M"
    end

    test "a rule that updates the struct of its own module" do
      source = """
      defmodule Rete.SnapshotTest.OwnUpdate do
        use Rete.Ruleset
        defstruct a: 1, b: 2
        defrule r({:a, x}), do: {:b, bump(%__MODULE__{b: x})}
        def bump(%__MODULE__{b: b} = s), do: %__MODULE__{s | b: b + 1}
      end
      """

      module = compile_source(source, Rete.SnapshotTest.OwnUpdate)

      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:a, 5}) |> Session.fire_rules() |> Session.facts()
      assert {:b, struct(module, b: 6)} in facts
    end

    test "a plain atom module name takes an image under Rete.Image" do
      module =
        compile_source(
          "defmodule :rete_snapshot_erl_rules do use Rete.Ruleset\n" <>
            "defrule r({:a, x}), do: {:b, x} end",
          :rete_snapshot_erl_rules
        )

      assert {:ok, {image, _beam}} = module.__rete_image__()
      assert ["Rete", "Image", "M" <> _hash] = Module.split(image)
    end

    test "a rule body that uses quote and unquote" do
      source = """
      defmodule Rete.SnapshotTest.Quoted do
        use Rete.Ruleset
        defrule r({:a, x}), do: {:b, quote(do: unquote(x) + 1)}
      end
      """

      module = compile_source(source, Rete.SnapshotTest.Quoted)

      live = [module] |> Session.new() |> Session.insert({:a, 1}) |> Session.fire_rules()
      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      moved = loaded |> Session.insert({:a, 1}) |> Session.fire_rules()

      assert Session.facts(live) |> Enum.sort() == Session.facts(moved) |> Enum.sort()
    end

    test "a helper that builds and matches the struct of the module itself" do
      source = """
      defmodule Rete.SnapshotTest.OwnStruct do
        use Rete.Ruleset
        defstruct [:v, w: 2]
        defrule r({:a, x}), do: {:b, get(mk(x)), mk(x)}
        def mk(x), do: %__MODULE__{v: x}
        def get(%__MODULE__{v: v}), do: v
      end
      """

      module = compile_source(source, Rete.SnapshotTest.OwnStruct)

      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:a, 1}) |> Session.fire_rules() |> Session.facts()
      assert {:b, 1, struct(module, v: 1)} in facts
    end

    test "a :fact_type_fn of the ruleset module that no rule calls" do
      source = """
      defmodule Rete.SnapshotTest.OwnType do
        use Rete.Ruleset
        defrule r({:a, x}), do: {:b, x}
        def type(fact), do: elem(fact, 0)
      end
      """

      module = compile_source(source, Rete.SnapshotTest.OwnType)
      session = Session.new([module], fact_type_fn: Function.capture(module, :type, 1))

      {:ok, loaded} = session |> Session.dump!(@key) |> Session.load(@key)
      facts = loaded |> Session.insert({:a, 1}) |> Session.fire_rules() |> Session.facts()
      assert {:b, 1} in facts
    end

    # A fact is matched by equality, so the dump leaves a capture inside one alone. After the
    # load, the caller can still retract the fact that it inserted, and a fact inserted again
    # stays one fact through a second dump.
    test "a fact that holds a capture keeps its identity across a load" do
      source = """
      defmodule Rete.SnapshotTest.CaptureFact2 do
        use Rete.Ruleset
        defrule r({:h, f}), do: {:seen, f}
        def f(x), do: x
      end
      """

      module = compile_source(source, Rete.SnapshotTest.CaptureFact2)
      fact = {:h, Function.capture(module, :f, 1)}
      fired = [module] |> Session.new() |> Session.insert(fact) |> Session.fire_rules()

      {:ok, loaded} = fired |> Session.dump!(@key) |> Session.load(@key)
      assert fact in Session.facts(loaded)
      assert [] == loaded |> Session.retract(fact) |> Session.fire_rules() |> Session.facts()

      again = loaded |> Session.insert(fact) |> Session.fire_rules()
      {:ok, twice} = again |> Session.dump!(@key) |> Session.load(@key)
      assert 2 == twice |> Session.facts() |> Enum.count(&(&1 == fact))
    end

    test "a capture of a helper stays remote, so a loaded session dumps again" do
      source = """
      defmodule Rete.SnapshotTest.CaptureFact do
        use Rete.Ruleset
        defrule r({:a, x}), do: {:b, x, &__MODULE__.f/1}
        def f(x), do: x
      end
      """

      module = compile_source(source, Rete.SnapshotTest.CaptureFact)

      {:ok, {image, _beam}} = module.__rete_image__()
      {:ok, loaded} = [module] |> Session.new() |> Session.dump!(@key) |> Session.load(@key)
      grown = loaded |> Session.insert({:a, 1}) |> Session.fire_rules()

      assert [{:b, 1, fun}] = Enum.filter(Session.facts(grown), &match?({:b, _, _}, &1))
      assert {:module, ^image} = Function.info(fun, :module)
      assert {:type, :external} = Function.info(fun, :type)
      redump = Session.dump!(grown, @key)
      assert image in images_in(redump)
      assert {:ok, _again} = Session.load(redump, @key)
    end
  end

  # The hash covers the module name, so each test compiles one name twice, and purges the
  # module and its image in between, as a new node would see them.
  describe "the name of an image" do
    defp image_of(module, body) do
      {_result, _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule #{inspect(module)} do
            use Rete.Ruleset
            #{body}
          end
          """)
        end)

      {:ok, {image, _beam}} = module.__rete_image__()
      purge(module)
      purge(image)
      image
    end

    test "does not change when the rest of the module changes" do
      rule =
        "defrule r({:a, x}), do: {:b, helper(x)}\ndef helper(x), do: Enum.map([x], &(&1 + 1))"

      module = Rete.SnapshotTest.HashStable

      plain = image_of(module, rule)
      edited = image_of(module, "@foo 1\ndef other, do: &(&1)\n" <> rule)

      assert plain == edited
    end

    test "tells a field access from a call with parentheses" do
      rule = "defrule r({:a, m}), do: {:b, f(m)}\n"
      module = Rete.SnapshotTest.HashParens

      assert image_of(module, rule <> "defp f(m), do: m.count") !=
               image_of(module, rule <> "defp f(m), do: m.count()")
    end
  end

  describe "loading an image" do
    # The loads race with no lock. A load that finds old code gets `:not_purged`, and the
    # image is loaded already, so every caller gets `:ok`.
    test "many first loads of one image all succeed" do
      module = compile(Rete.SnapshotTest.Concurrent, :v1)
      {:ok, {image, beam}} = module.__rete_image__()
      purge(image)

      1..20
      |> Task.async_stream(fn _ -> Rete.Image.load(%{image => beam}) end,
        max_concurrency: 20
      )
      |> Enum.each(fn result -> assert {:ok, :ok} == result end)

      assert {:file, _} = :code.is_loaded(image)
    end
  end

  # The image must copy every way a rule reaches a helper of its own module. A call it
  # missed would run the helper of the node that loads the session. Nothing would say so,
  # because that helper exists and the check for missing functions passes.
  describe "helpers the rules reach" do
    defp helper_source(module, limit, guard, extra) do
      """
      defmodule #{inspect(module)} do
        use Rete.Ruleset
        #{extra}
        defrule flag({:order, cid, amt} when #{guard}), do: {:flagged, cid}
        def big?(amt), do: amt > #{limit}
      end
      """
    end

    # v1 flags above 100, and v2 above 1000. An order of 500 tells the two apart.
    defp flags_after_redeploy?(module, guard, extra \\ "") do
      Code.compile_string(helper_source(module, 100, guard, extra))
      snapshot = [module] |> Session.new() |> Session.dump!(@key)

      :code.purge(module)
      :code.delete(module)
      Code.compile_string(helper_source(module, 1000, guard, extra))

      {:ok, loaded} = Session.load(snapshot, @key)

      facts =
        loaded |> Session.insert({:order, 1, 500}) |> Session.fire_rules() |> Session.facts()

      {:flagged, 1} in facts
    end

    test "a call qualified with __MODULE__ runs the helper of the image" do
      assert flags_after_redeploy?(Rete.SnapshotTest.SelfCall, "__MODULE__.big?(amt)")
    end

    test "a call qualified with the module name runs the helper of the image" do
      module = Rete.SnapshotTest.NamedCall
      assert flags_after_redeploy?(module, "#{inspect(module)}.big?(amt)")
    end

    test "a capture of a helper runs the helper of the image" do
      assert flags_after_redeploy?(
               Rete.SnapshotTest.SelfCapture,
               "Enum.any?([amt], &__MODULE__.big?/1)"
             )
    end

    # `super` calls a hidden function that holds the overridden clauses. An image that
    # left it alone failed to compile, and took the ruleset module down with it.
    test "a helper that calls super compiles into the image, and keeps its version" do
      base = Rete.SnapshotTest.SuperBase

      Code.compile_string("""
      defmodule #{inspect(base)} do
        defmacro __using__(_opts) do
          quote do
            def bounded?(amt), do: amt < 10_000
            defoverridable bounded?: 1
          end
        end
      end
      """)

      extra = """
      use #{inspect(base)}
      def bounded?(amt), do: super(amt) and big?(amt)
      """

      assert flags_after_redeploy?(Rete.SnapshotTest.Super, "bounded?(amt)", extra)
    end

    # The rule text is the same in both versions, so no generated function changes. Only
    # the helper does, and the image name still tells the two versions apart.
    test "a change to a helper alone makes a session built before it not the latest" do
      module = Rete.SnapshotTest.HelperOnly
      Code.compile_string(helper_source(module, 100, "big?(amt)", ""))
      session = Session.new([module])

      :code.purge(module)
      :code.delete(module)
      Code.compile_string(helper_source(module, 1000, "big?(amt)", ""))

      refute Session.latest?(session)
    end
  end

  describe "on a node that never compiled the ruleset" do
    setup do
      {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: code_path_args()})
      on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
      %{peer: peer}
    end

    test "a loaded session fires and answers queries by its original name", %{peer: peer} do
      module = compile(Rete.SnapshotTest.Remote, :v1)
      snapshot = module |> v1_session() |> Session.dump!(@key)

      assert false == :peer.call(peer, :code, :is_loaded, [module])

      {:ok, loaded} = :peer.call(peer, Session, :load, [snapshot, @key])
      grown = :peer.call(peer, Session, :insert, [loaded, [{:order, 2, 500}, {:refund, 1}]])
      grown = :peer.call(peer, Session, :fire_rules, [grown])

      assert [:v1] == :peer.call(peer, Session, :query, [grown, {module, :flagged}, [cid: 2]])

      facts = :peer.call(peer, Session, :facts, [grown])
      assert [{:clean, 2, :v1}] == Enum.filter(facts, &match?({:clean, _, _}, &1))
    end

    test "a rule that calls a module the node lacks does not load", %{peer: peer} do
      Code.compile_string("""
      defmodule Rete.SnapshotTest.Helper do
        def big?(amt), do: amt > 100
      end

      defmodule Rete.SnapshotTest.Needy do
        use Rete.Ruleset
        defrule flag({:order, cid, amt} when Rete.SnapshotTest.Helper.big?(amt)), do: {:flagged, cid}
      end
      """)

      snapshot = [Rete.SnapshotTest.Needy] |> Session.new() |> Session.dump!(@key)

      assert {:error, {:missing, [{Rete.SnapshotTest.Helper, :big?, 1}]}} ==
               :peer.call(peer, Session, :load, [snapshot, @key])
    end

    # The peer receives a loaded session as a term, and has never compiled or loaded its
    # image. A snapshot without that code would only fail later, where it loads.
    test "a session that captures an image this node lacks does not dump", %{peer: peer} do
      module = compile(Rete.SnapshotTest.Handoff, :v1)
      {:ok, loaded} = module |> v1_session() |> Session.dump!(@key) |> Session.load(@key)

      assert {:error, {:no_beam, image}} = :peer.call(peer, Session, :dump, [loaded, @key])
      assert Rete.Image.image?(image)

      assert_raise ArgumentError, ~r/has no beam/, fn ->
        :peer.call(peer, Session, :dump!, [loaded, @key])
      end
    end

    # The registry write on the load path is what lets the peer dump a session whose image
    # it only ever loaded.
    test "a node that loaded a snapshot dumps it again", %{peer: peer} do
      module = compile(Rete.SnapshotTest.PeerRedump, :v1)
      snapshot = module |> v1_session() |> Session.dump!(@key)

      {:ok, loaded} = :peer.call(peer, Session, :load, [snapshot, @key])
      fresh = :peer.call(peer, Session, :from_network, [Session.network(loaded)])

      for session <- [loaded, fresh] do
        redump = :peer.call(peer, Session, :dump!, [session, @key])
        assert images_in(snapshot) == images_in(redump)
      end

      redump = :peer.call(peer, Session, :dump!, [loaded, @key])
      {:ok, again} = :peer.call(peer, Session, :load, [redump, @key])
      assert [:v1] == :peer.call(peer, Session, :query, [again, {module, :flagged}, [cid: 1]])
    end

    test "a captured function the node lacks does not load", %{peer: peer} do
      types =
        compile_source(
          "defmodule Rete.SnapshotTest.Types, do: def(type(fact), do: elem(fact, 0))",
          Rete.SnapshotTest.Types
        )

      module = compile(Rete.SnapshotTest.Typed, :v1)

      snapshot =
        [module]
        |> Session.new(fact_type_fn: Function.capture(types, :type, 1))
        |> Session.dump!(@key)

      assert {:error, {:missing, [{types, :type, 1}]}} ==
               :peer.call(peer, Session, :load, [snapshot, @key])
    end
  end

  describe "what a snapshot holds" do
    test "a retracted fact is not in the snapshot" do
      others = for cid <- 1..10, do: {:customer, cid}

      session =
        [Rete.Doc.Orders]
        |> Session.new()
        |> Session.insert([{:customer, 777_123_456} | others])
        |> Session.fire_rules()
        |> Session.retract({:customer, 777_123_456})
        |> Session.fire_rules()

      snapshot = Session.dump!(session, @key)

      refute snapshot |> body_state() |> inspect(limit: :infinity) =~ "777123456"

      {:ok, loaded} = Session.load(snapshot, @key)
      more = [{:order, 1, 900}, {:order, 777_123_456, 900}]

      assert session |> Session.insert(more) |> Session.fire_rules() |> Session.facts() ==
               loaded |> Session.insert(more) |> Session.fire_rules() |> Session.facts()
    end

    # A snapshot holds these structs as they are. A body from another shape still decodes,
    # and it fails later inside the engine. Only a new `@format` makes `load/2` refuse it.
    test "the structs a snapshot holds have the shape of this format" do
      {:ok, modules} = :application.get_key(:rete, :modules)

      shapes =
        for module <- Enum.sort([Taxo | modules]),
            module != Rete.Session,
            Code.ensure_loaded?(module),
            function_exported?(module, :__struct__, 0),
            into: %{},
            do:
              {module,
               module.__struct__() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()}

      {:rete_session, format, _signature, _body} =
        [Rete.Doc.Orders] |> Session.new() |> Session.dump!(@key) |> :erlang.binary_to_term()

      assert {format, shapes} == {1, @shapes}, """
      A struct that a snapshot holds changed shape. Increase @format in Rete.Snapshot, \
      then update @shapes and the format in this test.\
      """
    end
  end

  describe "what is an image" do
    # A module with the name of an image, and no `@rete_image`, is a module of the user. A
    # dump must not ask for its beam.
    test "a module of the user with the name of an image is not an image" do
      [{fake, _beam}] =
        Code.compile_string("""
        defmodule Rete.SnapshotTest.Fake.Image.M0123456789ABCDEF do
          def type(fact), do: elem(fact, 0)
        end
        """)

      refute Rete.Image.image?(fake)

      module = compile(Rete.SnapshotTest.FakeImageHolder, :v1)
      session = [module] |> Session.new() |> Session.insert({:holder, &fake.type/1})

      assert {:ok, _snapshot} = Session.dump(session, @key)
    end

    test "an image is one" do
      module = compile(Rete.SnapshotTest.RealImage, :v1)
      {:ok, {image, _beam}} = module.__rete_image__()

      assert Rete.Image.image?(image)
      assert {:ok, {^image, _beam}} = Rete.Image.fetch(module)
      assert :none == Rete.Image.fetch(Enum)
    end
  end

  describe "what a snapshot refuses" do
    test "a value that is not a binary is invalid" do
      assert {:error, :invalid} == Session.load(nil, @key)

      error = assert_raise ArgumentError, fn -> Session.load!(nil, @key) end
      assert error.message =~ "not a snapshot"
    end

    test "an anonymous :fact_type_fn cannot be dumped" do
      module = compile(Rete.SnapshotTest.Anonymous, :v1)
      session = Session.new([module], fact_type_fn: fn fact -> elem(fact, 0) end)

      assert {:error, {:not_portable, fun}} = Session.dump(session, @key)
      assert is_function(fun, 1)

      error = assert_raise ArgumentError, fn -> Session.dump!(session, @key) end
      assert error.message =~ "anonymous function"
    end

    test "dump, dump!, load and load! raise on a secret that is not a non-empty binary" do
      module = compile(Rete.SnapshotTest.BadSecret, :v1)
      session = v1_session(module)
      snapshot = Session.dump!(session, @key)

      for secret <- ["", nil, :key, 42, {:ok, "s3cr3t-value"}] do
        for call <- [
              fn -> Session.dump(session, secret) end,
              fn -> Session.dump!(session, secret) end,
              fn -> Session.load(snapshot, secret) end,
              fn -> Session.load!(snapshot, secret) end
            ] do
          error = assert_raise ArgumentError, ~r/non-empty binary/, call
          # A caller that passes `{:ok, key}` by mistake must not find its key in a log.
          refute error.message =~ "s3cr3t-value"
        end
      end
    end

    test "a snapshot loads only with the key that signed it" do
      module = compile(Rete.SnapshotTest.Signed, :v1)
      signed = module |> v1_session() |> Session.dump!("k1")

      assert {:ok, _} = Session.load(signed, "k1")
      assert {:error, :signature} == Session.load(signed, "k2")
    end

    test "dump returns the binary in a tuple, and the bang forms return the plain values" do
      module = compile(Rete.SnapshotTest.Bang, :v1)
      session = v1_session(module)

      assert {:ok, binary} = Session.dump(session, @key)
      assert {:ok, loaded} = Session.load(binary, @key)
      assert %Session{} = bang = session |> Session.dump!(@key) |> Session.load!(@key)
      assert Session.facts(loaded) == Session.facts(bang)
    end

    test "load! raises with the reason that load returns" do
      module = compile(Rete.SnapshotTest.BangErrors, :v1)
      signed = module |> v1_session() |> Session.dump!("k1")

      for {binary, key, text} <- [
            {signed, "k2", "does not match the secret"},
            {"not a snapshot", "k1", "not a snapshot"}
          ] do
        error = assert_raise ArgumentError, fn -> Session.load!(binary, key) end
        assert error.message =~ "cannot load the snapshot"
        assert error.message =~ text
      end
    end

    test "a tampered body fails the signature" do
      {format, signature, body} = parts(Rete.SnapshotTest.Tampered)

      forged = :erlang.term_to_binary({:rete_session, format, signature, body <> <<0>>})
      assert {:error, :signature} == Session.load(forged, @key)
    end

    test "a missing, short or odd signature fails, and does not raise" do
      {format, signature, body} = parts(Rete.SnapshotTest.OddSignature)

      for bad <- [nil, binary_part(signature, 0, 4), :not_a_binary] do
        forged = :erlang.term_to_binary({:rete_session, format, bad, body})
        assert {:error, :signature} == Session.load(forged, @key)
      end
    end

    test "a compressed envelope is refused before it is decoded" do
      {format, signature, body} = parts(Rete.SnapshotTest.Compressed)

      # Built by hand, as an attacker would. `term_to_binary/2` skips compression when it
      # would not shrink the term, and the body inside is compressed already.
      <<131, inner::binary>> = :erlang.term_to_binary({:rete_session, format, signature, body})
      compressed = <<131, 80, byte_size(inner)::32, :zlib.compress(inner)::binary>>
      assert {:rete_session, ^format, _, _} = :erlang.binary_to_term(compressed)

      assert {:error, :invalid} == Session.load(compressed, @key)
    end

    test "an envelope of this format with a body that is not a binary is invalid" do
      assert {:error, :invalid} ==
               Session.load(:erlang.term_to_binary({:rete_session, 1, nil, :not_a_binary}), @key)
    end

    test "a signed body with images that are not beams of image names is undecodable" do
      {_format, _signature, body} = parts(Rete.SnapshotTest.BadImages)
      decoded = :erlang.binary_to_term(body)

      [{_real, real_beam} | _] = Map.to_list(decoded.images)

      for images <- [
            %{Foo.Bar => :x},
            %{"x" => "junk"},
            %{Enum => "junk"},
            %{Foo.Bar => real_beam},
            %{
              :rete_snapshot_test_not_an_image =>
                on_load_fails(:rete_snapshot_test_not_an_image, "17")
            }
          ] do
        assert {:error, :undecodable} ==
                 Session.load(forge(%{decoded | images: images}), @key)
      end

      bad_state = %{decoded | state: %{decoded.state | network: nil}}
      assert {:error, :undecodable} == Session.load(forge(bad_state), @key)
    end

    test "an image that does not load is reported with the release that compiled it" do
      {_format, _signature, body} = parts(Rete.SnapshotTest.NoLoad)
      decoded = :erlang.binary_to_term(body)
      name = :"Elixir.Rete.SnapshotTest.NoLoad.Image.M00000000000000A1"

      forged =
        forge(%{decoded | images: Map.put(decoded.images, name, on_load_fails(name, "17"))})

      assert {:error, {:image, ^name, :on_load_failure, "17"}} = Session.load(forged, @key)

      error = assert_raise ArgumentError, fn -> Session.load!(forged, @key) end
      assert error.message =~ "OTP 17 compiled it"
    end

    # The release of each image comes from its own beam. A dump on a node of another release
    # does not change it.
    test "every image of a snapshot records the release that compiled it" do
      snapshot =
        Rete.SnapshotTest.OtpRecorded |> compile(:v1) |> v1_session() |> Session.dump!(@key)

      {:rete_session, _format, _signature, body} = :erlang.binary_to_term(snapshot)

      for {_image, beam} <- :erlang.binary_to_term(body).images do
        assert System.otp_release() == Rete.Image.otp(beam)
      end
    end

    test "the error of an image gives the release only when it differs from this node" do
      {_format, _signature, body} = parts(Rete.SnapshotTest.SameOtp)
      decoded = :erlang.binary_to_term(body)
      name = :"Elixir.Rete.SnapshotTest.SameOtp.Image.M00000000000000A2"
      beam = on_load_fails(name, System.otp_release())

      forged = forge(%{decoded | images: Map.put(decoded.images, name, beam)})
      error = assert_raise ArgumentError, fn -> Session.load!(forged, @key) end

      assert error.message =~ ":on_load_failure"
      refute error.message =~ "OTP"
    end

    # The order matters for security: a body under a wrong signature must never reach the
    # loader. This image's `on_load` hook leaves a mark, so a load that ran it shows.
    test "a wrong signature stops the load before any image in the body loads" do
      {format, signature, body} = parts(Rete.SnapshotTest.SignatureFirst)
      decoded = :erlang.binary_to_term(body)
      name = :rete_snapshot_test_never_loads
      mark = {__MODULE__, name}

      forged_body =
        :erlang.term_to_binary(%{decoded | images: %{name => on_load_marks(name, mark)}})

      forged = :erlang.term_to_binary({:rete_session, format, signature, forged_body})

      assert {:error, :signature} == Session.load(forged, @key)
      assert :absent == :persistent_term.get(mark, :absent)
      assert false == :code.is_loaded(name)
    end

    test "a snapshot with bytes after it is refused" do
      module = compile(Rete.SnapshotTest.Trailing, :v1)
      snapshot = module |> v1_session() |> Session.dump!(@key)

      assert {:ok, _} = Session.load(snapshot, @key)
      assert {:error, :invalid} == Session.load(snapshot <> "junk", @key)
    end

    test "a binary that is not a snapshot, or another format, is refused" do
      assert {:error, :invalid} == Session.load("not a snapshot", @key)
      assert {:error, :invalid} == Session.load(:erlang.term_to_binary(:other), @key)

      assert {:error, :invalid} ==
               Session.load(:erlang.term_to_binary({:rete_session, :x, nil, <<>>}), @key)
    end

    # A format is reported only once the signature holds, so it is one the key holder wrote.
    test "another format is reported only under a good signature" do
      body = :erlang.term_to_binary(:any)
      signed = :erlang.term_to_binary({:rete_session, 99, sign(99, body), body})

      assert {:error, {:format, 99}} == Session.load(signed, @key)

      assert {:error, :signature} ==
               Session.load(:erlang.term_to_binary({:rete_session, 99, nil, body}), @key)
    end

    # The format is signed with the body. A snapshot relabelled as another format fails the
    # check, so a body is never read under a format it was not written in.
    test "a relabelled format fails the signature" do
      {format, signature, body} = parts(Rete.SnapshotTest.Relabelled)
      relabelled = :erlang.term_to_binary({:rete_session, format + 1, signature, body})

      assert {:error, :signature} == Session.load(relabelled, @key)
    end

    # Signed here with the real key, so the bad body passes the check and reaches the
    # decoder. A bug on the side that holds the key must still give an error, and not a
    # crash.
    test "a signed body that does not decode, or decodes to the wrong shape, is refused" do
      for body <- [<<131, 1, 2, 3>>, :erlang.term_to_binary(%{other: 1})] do
        snapshot = :erlang.term_to_binary({:rete_session, 1, sign(1, body), body})

        assert {:error, :undecodable} == Session.load(snapshot, @key)
      end
    end

    # The way the docs give to carry what a listener collected: read it before the dump,
    # and attach it again after the load.
    test "listeners do not travel, and attach again after the load" do
      module = compile(Rete.SnapshotTest.Listened, :v1)

      session =
        [module]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:customer, 1})

      collected = Session.listener_state(session, Collect)
      {:ok, loaded} = session |> Session.dump!(@key) |> Session.load(@key)

      assert nil == Session.listener_state(loaded, Collect)

      resumed =
        loaded
        |> Session.with_listener(Collect, collected)
        |> Session.insert({:customer, 2})

      assert [
               {:fact_inserted, {:customer, 1}, :asserted},
               {:fact_inserted, {:customer, 2}, :asserted}
             ] ==
               Collect.by_tag(resumed, :fact_inserted)
    end
  end

  # Compiles `source` and returns `module` as the result names it. A literal module name
  # in the test would draw a warning, because the compiler cannot see a module that only
  # exists once the test runs.
  defp compile_source(source, module) do
    {compiled, _beam} = source |> Code.compile_string() |> List.keyfind(module, 0)
    compiled
  end

  # A ruleset whose rule calls a helper that a later `@before_compile` hook defines, so the
  # module compiles with no image. It flags orders above 1000, as the v2 of `source/2` does.
  defp late_hook_ruleset(module, lib) do
    source = """
    defmodule #{inspect(lib)} do
      defmacro __using__(_opts), do: quote(do: @before_compile(#{inspect(lib)}))
      defmacro __before_compile__(_env), do: quote(do: def(big?(amt), do: amt > 1000))
    end

    defmodule #{inspect(module)} do
      use Rete.Ruleset
      use #{inspect(lib)}
      defrule flag({:order, cid, amt} when big?(amt)), do: {:flagged, cid, :v2}
      defquery flagged(cid)({:flagged, cid, tag}), do: tag
    end
    """

    compile_source(source, module)
  end

  # A beam whose `on_load` hook succeeds and writes `mark` to `:persistent_term`.
  defp on_load_marks(name, mark) do
    {:ok, ^name, beam} =
      :compile.forms(
        [
          {:attribute, 1, :module, name},
          {:attribute, 1, :export, [mark: 0]},
          {:attribute, 1, :on_load, {:mark, 0}},
          {:function, 1, :mark, 0,
           [
             {:clause, 1, [], [],
              [
                {:call, 1, {:remote, 1, {:atom, 1, :persistent_term}, {:atom, 1, :put}},
                 [:erl_parse.abstract(mark), {:atom, 1, true}]},
                {:atom, 1, :ok}
              ]}
           ]}
        ],
        [:binary]
      )

    beam
  end

  # A beam whose `on_load` hook fails, so loading it is an error.
  # `otp` stands in for the release that compiled an image, as `@rete_image` records it.
  defp on_load_fails(name, otp) do
    {:ok, ^name, beam} =
      :compile.forms(
        [
          {:attribute, 1, :module, name},
          {:attribute, 1, :rete_image, %{otp: otp}},
          {:attribute, 1, :export, [fail: 0]},
          {:attribute, 1, :on_load, {:fail, 0}},
          {:function, 1, :fail, 0, [{:clause, 1, [], [], [{:atom, 1, :error}]}]}
        ],
        [:binary]
      )

    beam
  end

  # The image modules a snapshot carries.
  defp images_in(snapshot) do
    {:rete_session, _format, _signature, body} = :erlang.binary_to_term(snapshot)
    body |> :erlang.binary_to_term() |> Map.fetch!(:images) |> Map.keys()
  end

  # A snapshot around a body of your choosing, signed with the real key.
  defp forge(decoded) do
    body = :erlang.term_to_binary(decoded)
    :erlang.term_to_binary({:rete_session, 1, sign(1, body), body})
  end

  # The signature `dump/2` writes: an HMAC over the format and the body.
  defp sign(format, body), do: :crypto.mac(:hmac, :sha256, @key, [<<format::32>>, body])

  # The second purge removes the code that the delete made old, so nothing is left.
  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp body_state(snapshot) do
    {:rete_session, _format, _signature, body} = :erlang.binary_to_term(snapshot)
    %{state: state} = :erlang.binary_to_term(body)
    state
  end

  # The three parts of a real snapshot, for a test that forges one of them.
  defp parts(module) do
    {:rete_session, format, signature, body} =
      module |> compile(:v1) |> v1_session() |> Session.dump!(@key) |> :erlang.binary_to_term()

    {format, signature, body}
  end

  # Every path this node uses, so the peer finds rete and Elixir. A module that
  # `Code.compile_string/1` made has no path, so the peer never finds the rulesets.
  defp code_path_args, do: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
end
