# Snapshots

This document covers `Rete.Session.dump/2` and `Rete.Session.load/2`. It is the companion
to `ir.md` (the code a ruleset compiles to) and `network.md` (the captures that hold it).
`dump!/2` and `load!/2` do the same work. They return the plain value, and raise where the
others return an error.

Status: implemented, end to end.

---

## 1. The problem

A snapshot must load on a node that runs another version of the program. The loaded session
must then run the rules it was dumped with, and not the rules of that node.

A session is plain data, with one exception. The network holds functions, and each one is a
capture such as `&MyRules.__rhs_flag__/2`. A capture is a name, not code. `term_to_binary`
writes it as `{MyRules, :__rhs_flag__, 2}`. On another node, that name finds the code of
that node, or no code.

A node holds one current version of a module. So the v1 `MyRules` cannot load next to the
v2 `MyRules`. The rules of a snapshot must live under a name that no other version uses.

## 2. Images

`use Rete.Ruleset` compiles a second module beside the ruleset module. This is the
**image**. For `MyRules`, it is `MyRules.Image.M<hash>`, so the name shows where an image
came from. When a module is defined, the code server looks for a file named
`<name>.beam`, and a file name holds at most 255 bytes. So a module name too long for that
takes `Rete.Image.M<hash>` instead. So does a module with a plain atom name, such as
`:erl_rules`. `Rete.Image` builds the image in a `@before_compile`
hook. `use Rete.Ruleset` registers that hook right after its own, so the functions its own
hook defines, such as `get_version/0`, exist when the image copies them.

The image holds a copy of the functions the network captures. Each one is an alpha, a join
filter, a test or a right hand side. The copy also holds every helper of the module that
one of them calls locally, `def` or `defp`, followed to any depth. `Module.get_definition/3`
supplies the clauses. They are expanded AST, so an import is already a remote call, and a
macro is already gone.

A rule can also reach a helper of its own module in three other ways. The copy points each
one at the image, and then follows it:

| written | in the image |
|---|---|
| `__MODULE__.big?(x)` or `MyRules.big?(x)` | `big?(x)` |
| `&__MODULE__.big?/1` or `&MyRules.big?/1` | `&__MODULE__.big?/1`, where `__MODULE__` is now the image |
| `super(x)` in an overriding helper | a call to the hidden function that holds the overridden clauses |

Without this, the first two would run the `MyRules` of the node that loads the session. The
check for missing functions would not catch it, because that function exists. The third
would not compile, because the image declares nothing overridable.

A capture stays a remote capture. A local capture is a closure, and `dump/2` refuses a
closure. So a fact that held one could not be dumped a second time.

A capture of a function that the module does not define yet stays a capture of the module.
A later hook can define `fun/1` beside a `fun/0` that is defined. The copy keeps
`&MyRules.fun/1` as it is, and does not take it for a call of `fun/0`.

The image holds the `@rete_image` attribute in its beam. It marks the module as an image,
so a loaded module of the user with a name of the same form is not taken for one. It also records
the OTP release that compiled the image. `load/2` reads that release from the beam without
a load, and names it in the error when the release differs from the node.

The ruleset module gets `__rete_image__/0`. It returns one of three values:

* `{:ok, {image, beam}}` — the image module and its `.beam` binary.
* `nil` — the module declares no production.
* `{:unavailable, reason}` — the image did not compile.

`Rete.Image.fetch/1` reads it for the build, for `Rete.Session.latest?/1` and for a dump.

### How the image compiles

The image compiles with the file and the line of the ruleset, and with none of its imports.
The clauses are expanded already, so they need no import. A late import could otherwise
clash with the copy of a helper of the same name. Kernel is narrowed to `def`, `defp` and
`@` for the same reason.

The image compiles in a process of its own. The compiler tracks the modules that its own
processes define. It writes them to `ebin`, and it checks them for undefined calls and for
types. Coverage and Dialyzer then read them from `ebin`. An image is none of those things.
It is data inside `__rete_image__/0`, and it loads from that binary when a snapshot does.
So an image is never in `ebin`, in coverage, or in a Dialyzer run, and the warnings of the
ruleset module are not repeated against it. The diagnostics of the image compile itself are
captured and not printed.

The process of the image cannot wait for a module that the compiler has not finished. So
the process of the ruleset loads every struct module that the copied code names before the
image compiles. The ruleset module already needed each of those structs, so this waits for
nothing new.

Two rewrites keep the copy compiling. The struct of the module itself becomes a map with
`:__struct__`, because that module is still compiling the image. Expansion already filled
in its fields, and in a pattern the map matches what the struct matched. An update of it
becomes a map update. See §6 for what that changes before Elixir 1.20. A call that `quote`
expands to goes through `:erlang.apply/3`, because the compiler reads a direct call of
`:elixir_quote.unquote/1` inside a function as an unquote fragment.

One VM compiles an image once. The beam goes into the same `:persistent_term` registry that
`load/2` writes. A recompile of the same rules then takes the beam from there, and does not
replace a loaded module.

### When a module has no image

The ruleset module still compiles. An image must never stop the ruleset module from
compiling. `__rete_image__/0` returns `{:unavailable, reason}`. A build with images, the
default, raises `ArgumentError` with that reason. `images: false` builds the module for
tests, and `dump/2` then returns `{:error, {:no_image, module, reason}}`.

The usual cause is a helper that a `@before_compile` hook defines after the hook of
`use Rete.Ruleset`. Hooks run in the order they are registered, and a hook cannot add a
hook that runs later. So the image cannot see that helper. The fix is to put
`use Rete.Ruleset` after the `use` that defines the helper.

An image compile that takes more than two minutes stops. The module then has no image, and
its compile goes on. `:image_compile_timeout` in the `:rete` application environment sets
another limit, in milliseconds.

### The hash

The hash is SHA-256 over the module name, a format number, and the copied clauses, cut to
64 bits. The encoding of the hashed term is fixed, so a new OTP default does not rename an
image whose code did not change. The clauses keep only the metadata that changes what the
code does:

* `:version` and `:counter` tell apart two variables of one name. `:counter` counts across
  the whole module, so it is numbered again inside each definition. An edit elsewhere in
  the module thus leaves the name alone.
* `:no_parens` stays, because `map.key` and `map.key()` compile to different code.

Lines and files go. So the name depends on what the code does, and not on where it sits in
the file. A line or a file inside the code itself stays, because it is a value the code
returns. `Logger`, `dbg` and `__ENV__` expand to such values. A rule that uses them gets a
new image name when it moves, or when it builds from another path.

Two properties follow from the hash:

* **Different code gets a different name.** Images of many versions load on one node
  together.
* **The same code gets the same name.** An image loads once, and every session of that
  version shares it. A rebuild with no change to the rules keeps the name.

### A session runs its images

`Rete.Compiler.build/2` points the network at the images by default. It loads each image
with `Rete.Image.load/1`, and `Rete.Image.target/2` replaces each capture of a ruleset
module with the same capture of its image. It does this to the productions, before it
builds the network. Every function of the network comes from them, and they are much
smaller than the network. A capture always reaches the current code of the module it
names. A capture of `MyRules` would reach v2 after a hot upgrade, while the network still
has the shape of v1. A session would then run code of two versions, or raise when it
fires. A capture of the image reaches v1 until the session is built again.

The network records the image of each module in `:built_images`, as
`%{module => image}`. `Rete.Session.latest?/1` compares the record with the image that each
module offers now. A different name means other code, because the name is a hash of the
code.

`images: false` keeps the captures of `MyRules`. A coverage tool counts the calls of a
module, and the image is another module. So the rules show no coverage when they run in
the image. `config :rete, images: false` sets the default for a test env. A network built
this way records no images, so `latest?/1` always returns `true`. It calls the code of the
node, and it is not safe across a hot upgrade.

## 3. Dump

By default, the network runs its images already (§2). So `dump/2` has little to change.
Under `images: false`, a live session keeps its captures of `MyRules`, and a stack trace
names the module you wrote. `dump/2` changes the snapshot, and not the session:

1. Listeners go, always. A listener only watches, and its state can hold a pid that means
   nothing on another node. The caller attaches listeners again after `load/2`. The buckets
   of the memory and the agenda are compacted. A bucket keeps a retracted item as a
   tombstone until the tombstones outnumber the live items. So without this, a retracted
   fact could still be in the snapshot. Work that `fire_rules/2` has not done yet stays in
   the queue and travels with the snapshot, such as a pending retract.
2. With images, the network captures images already, and this step changes nothing. Under
   `images: false`, `Rete.Image.target/2` replaces each capture of a ruleset module with
   the same capture of the image the module offers now. After a hot upgrade, that image
   does not fit the old network. So dump such a session before an upgrade. This covers the
   network only. A capture inside a fact stays as it is, because a fact is matched by
   equality. Changing it would make a retract of the same fact miss after the load.
3. `Rete.Image.captures/1` finds any function that is not a remote capture, and `dump/2`
   returns `{:error, {:not_portable, fun}}`. An anonymous function runs only on the build
   that made it. An anonymous `:fact_type_fn` is the usual cause.
4. The snapshot takes the images that the state still captures. An image comes from a
   ruleset module of the network, or from the registry of images that this node compiled
   or loaded. So a loaded session dumps again with its v1 images, on
   a node that runs v2. So does a session that `from_network/1` built over the network of a
   loaded session. A captured image with no beam anywhere makes `dump/2` return
   `{:error, {:no_beam, image}}`.
   A session that arrived by distribution from a node that runs other rules can cause
   this. Dump it on the node that built or loaded it.

   Only a ruleset module that the state still captures can make `dump/2` return an error
   for a missing image. The v2 module of a node does not matter to a loaded v1 session,
   even if it has no image.

   A capture of a ruleset function that no rule calls stays a capture of the module, because
   the image did not copy it. The taxonomy is never targeted at an image. So a
   `:fact_type_fn`, even one defined in the ruleset module, runs the version of the node
   that loads the session.

The payload is two layers:

```elixir
{:rete_session, format, signature, body}
body = term_to_binary(%{images: %{image => beam}, state: state}, [:compressed, minor_version: 2])
```

`signature` is the HMAC-SHA256 of the format and `body` under the key, and every snapshot
has one. The format is signed too, so a snapshot cannot be relabelled as another format
without the key. The outer layer holds only atoms that every node has. So `load/2` reads it
with `:safe`, and it checks the signature before it decodes the body. A compressed outer
layer is refused before it is read, because `dump/2` never writes one. `:safe` does not
stop decompression, so a small input could otherwise inflate to a term many times its size
before the signature check runs. A binary with bytes after the outer term is refused as
well, because `dump/2` never writes one either.

## 4. Load

1. Check the HMAC-SHA256 of the format and the body against the key. A missing, short or
   wrong signature returns `{:error, :signature}`, and nothing in the body is decoded. The
   key is a required argument of `dump/2` and `load/2`, so no snapshot goes without this
   check.
2. Refuse an unknown format. The body holds the engine's own structs, such as
   `Rete.Memory`, `Rete.Agenda` and the network nodes. A release that changes one of them
   increases `@format` in `Rete.Snapshot`. This comes after the signature, so the format it
   reports is one the key holder wrote.
3. Decode the body. This cannot use `:safe`, because the image names are new atoms. A body
   that does not decode, or decodes to the wrong shape, returns `{:error, :undecodable}`.
   The signature is good, so the likely cause is another release of OTP or of rete. Each
   image must be a beam of the module it is filed under.
4. Load each image that the node has not loaded, with `:code.load_binary/3`. This takes no
   lock. Two first loads of one image can race, and the second makes the first copy old
   code. A third load then returns `{:error, :not_purged}`, and that means the image is
   loaded. The code is the same in every copy, and rete never purges an image. So no
   process dies.
5. Check every function that the state captures and that the images call. Each one must
   exist on this node. A missing one returns `{:error, {:missing, mfas}}`.

## 5. Queries keep their names

`target/2` changes captures and nothing else. A production keeps `{MyRules, :flagged}` as
its identity. So `Rete.Session.query(session, {MyRules, :flagged}, cid: 1)` reaches the v1
query on any node.

`MyRules.flagged(session, 1)` is a function of the `MyRules` on the node. It works where that
module declares the query with the same head. On a node with no `MyRules`, use
`Rete.Session.query/3`.

## 6. Limits

* **A later hook that overrides a helper is not seen.** The image copies a helper as it
  stood when the hook of `use Rete.Ruleset` ran. A hook that runs later and overrides that
  helper changes the module, and not the image. A session then runs the first version,
  and nothing reports it. Put `use Rete.Ruleset` after any `use` whose hook overrides
  functions.
* **A remote call runs the code of the node.** The image copies the helpers of the ruleset
  module, and nothing else. A rule that calls `MyApp.Pricing.discount/1` runs the version of
  `MyApp.Pricing` on the node that loads it. Step 5 of the load makes sure that the function
  exists. It cannot make sure that the function behaves the same. Keep the logic a rule
  depends on in the ruleset module, or in a module that does not change.
* **A stack trace names the image.** By default, a rule runs in `MyRules.Image.M<hash>`.
  So a frame reads `MyRules.Image.M<hash>.__rhs_flag__/2`, and not
  `MyRules.__rhs_flag__/2`. The function name still names the rule.
* **`images: false` is not safe across a hot upgrade.** Its captures reach the current
  module. After an upgrade, a session runs code of two versions, or raises when it fires.
  This can happen inside one `fire_rules/2`. `Rete.Session.latest?/1` cannot see it, and a
  dump takes the image the module offers then. Use `images: false` in tests only.
* **OTP.** A beam from a newer OTP may not load on an older one. The error names the
  release that compiled the image, if it differs from the release of the node.
* **A struct update in a helper checks less before Elixir 1.20.** The copy turns
  `%MyRules{s | k: v}` into a map update. Since Elixir 1.20 that is what a struct update
  compiles to. An older Elixir also checks that `s` is a `MyRules`, and raises
  `BadStructError` if it is not. The copy does not check. So on Elixir 1.18 and 1.19, a
  loaded session accepts a value that the live session refuses.
* **Trust.** A snapshot holds code, and loading it runs that code. Decoding it also creates
  atoms, and the atom table of a node has a fixed size. Every snapshot is signed, and a
  snapshot that fails the check is not decoded. The check protects you only while the key
  stays secret. Keep it apart from the snapshot store.
* **Dynamic calls are not copied.** `apply(__MODULE__, :big?, [x])` runs the `MyRules` of the
  node, as a call to another module does. So do `struct(__MODULE__, fields)`, `struct!/2`
  and `raise __MODULE__`. Write the struct literal, `%__MODULE__{}`, to build the struct of
  the image.
* **A capture inside a fact runs the code of the node.** After the load, a fact that holds
  `&MyRules.helper/1` runs the `MyRules` of the node, as a remote call does. §3 step 2 gives
  the reason.
* **Images stay loaded.** Nothing purges an image that no session uses. A node that loads
  snapshots of many versions keeps every image it loaded. This is also true when `load/2`
  loads an image and then returns an error, such as `{:missing, mfas}`. Another session
  that loads or already runs on the node can need the same image.
* **A snapshot is not encrypted.** The signature protects the integrity of the snapshot,
  and not the data in it. Anyone who has the binary can decode the body with no key, and
  read every fact and every pending match. Encrypt the snapshots at rest if the facts are
  sensitive.
* **Listeners do not travel.** To carry what a listener collected, read it with
  `Rete.Session.listener_state/2` before the dump. Give it to `Rete.Session.with_listener/3`
  after the load.
