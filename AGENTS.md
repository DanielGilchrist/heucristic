# heucristic

A best-effort Crystal language server that does no type inference. See [README.md](README.md) for what it does, the trade-offs, shims and install.

Speed comes first, then honesty. A fast wrong answer and a slow right answer are both failures. Never guess a type to fill a gap. Types come only from what the source states: annotations, declared ivars, and assignments whose right-hand side is syntactically evident (a literal, `Const.new`, `[] of T`, `.as(T)`, an annotated variable). The result of a method call is never evident.

## Definition of done

```sh
crystal spec
crystal tool format
bin/ameba
```

All three must pass, with zero ameba failures. Never disable a lint rule. If a rule conflicts with the principles below, raise it with the user. Build ameba with `shards build ameba` on a fresh clone.

After a change that deletes or renames code, run each of these separately, because each tool ends in `exit` and a second entrypoint in the same run is marked dead:

```sh
crystal tool unreachable src/heucristic.cr spec/**/*_spec.cr tools/shims_check.cr
crystal tool unreachable src/heucristic.cr spec/**/*_spec.cr tools/probe.cr
crystal tool unreachable src/heucristic.cr spec/**/*_spec.cr tools/score.cr
```

It always exits 0. A method you touched in the output is dead code you left behind, so delete it.

A bug fix ships with a regression spec verified to fail against the bug.

After a resolver or check change, compare a build of `main` with your build on the projects below. On each:

- `bin/score <p> --check` prints `0 findings`, apart from known real defects, and meets the 25ms budget.
- `bin/score <p>` resolved does not fall, unless every call that stopped resolving was a wrong answer.
- `bin/score <p> --verify 100 --main <main>` reports `disagree: 0`.
- `bin/score <p> --features` reports 0 `EMPTY hovers`, 0 `CRASHES` and 0 `NO TARGET`, and `--features --verify N` reports no `FAIL`.
- This repo's own `--check` stays at 0. Declare ivars (see Invariants) or it regresses.

| Project | `--main` | Notes |
|---|---|---|
| this repo | `src/heucristic.cr` | |
| [pylon](https://github.com/DanielGilchrist/pylon) | `src/pylon.cr` | |
| [shoo](https://github.com/DanielGilchrist/shoo) | `src/main.cr` | |
| [tanda_cli](https://github.com/DanielGilchrist/tanda_cli) | `src/main.cr` | |
| [shrimp](https://github.com/DanielGilchrist/shrimp) | `src/shrimp_sdl.cr` | Pass `--define sdl` to every `bin/score` run |
| [yarn_on](https://github.com/DanielGilchrist/yarn_on) | `src/yarn_on.cr` | Lucky app, heavy on macros. `--verify` takes a few minutes |
| [kebab](https://github.com/DanielGilchrist/kebab) | none | Library, no main target, so skip `--verify` |
| [lavinmq](https://github.com/cloudamqp/lavinmq) | `src/lavinmq.cr` | Large and mostly unannotated. `--check` reports a few findings that are real defects in methods nothing calls |

Clone each one outside `/tmp` (macOS purges it) and run `shards install` in it. lavinmq needs `shards install --ignore-crystal-version --skip-postinstall --skip-executables`.

Don't automatically clone and run against these repos, ask the human first. `AGENTS.local.md` should be created once decided to instruct future runs on benchmarking against repos.

## Tools

```sh
shards build heucristic probe score shims-check --release
script/build-semantic                                # bin/heucristic-semantic, needs llvm-config
bin/probe <file.cr> <line>:<col> [action]           # real binary over stdio, 1-based; actions in tools/probe/action.cr
bin/shims-check                                      # orphans, redundant and now-declared generated shims must all be zero
bin/score <project> [flags]
```

Rebuild before `bin/probe`, it does not rebuild the server. Anything the probe shows must also have a spec in `spec/heucristic/server/` using `LspClient.in_process`.

`bin/score` flags:

- no flag: resolve every call under the project's `src/` and bucket unknowns by reason, with an example site each.
- `--check`: run the checks and the performance budget. Exits 2 on findings, 3 if any file takes over 25ms to re-check with warm caches.
- `--why`: with `--check`, say why each skipped call was not checkable.
- `--only <suffix>`: restrict the sweep and timing to one file, for profiling with `sample`.
- `--at src/file.cr:LINE`: for every call on the line, print the receiver, argument types with `Precision`, candidate defs with verdicts, and the findings within 40 lines. Use it to debug a false positive.
- `--verify N --main src/x.cr`: re-check N random resolved calls against `crystal tool implementations` from the project root. The wrong bucket, where we disagree with the compiler, must stay empty.
- `--define <flag>`: a compile-time flag, repeatable.
- `--features`: hover and definition at every identifier position (calls, locals, ivars, constants, block parameters, def names, requires), bucketed by kind. Lists empty hovers, crashes, positions the cursor can't find and positions with no definition. Exits 2 on any of the first three.
- `--features --verify N [--main src/x.cr]`: also checks N answered definitions per kind against the source, and calls against the compiler when `--main` is given. Exits 2 on a failure.
- `--specs` adds `spec/` to `--features`. `--no-macros` skips the semantic helper.

## Architecture

The pipeline is: parse one file, extract its declarations into a per-file index, look names up across indexes on request, answer or say unknown. Everything is under `src/heucristic/`.

- `protocol/`: `Framing`, `Decoder`, `Encoder`, `Transport` (serialises writers). Types come from the `lsprotocol` shard.
- `document/`: `Text` converts between LSP UTF-16 positions, byte offsets and the compiler's `Point`. `Region` is an inclusive range of points, the compiler's end location included. `Edit`, `Store`.
- `syntax/`: `Syntax.parse` quarantines `Crystal::Parser`. `Cursor.find` returns `Target | NoTarget`, where `Target` is `OnDef | OnCall | OnPath | OnVar | OnInstanceVar | OnLiteral | OnAutocast | OnRequire`. A literal is a target only when no inner target matched and the point is in its `LiteralExtent`: `whole` for scalars and autocastable literals (a heredoc is its opener and its body), `delimiters` for containers (brackets, `of`, a range's operator, a proc's arrow). Inside `{{ }}`, `{% %}` and macro bodies `MacroCode` yields only paths, so calls, variables and literals there give no target. `OnAutocast` is a number or symbol literal with the `Placement` (`Free`, `Declared`, `InstanceVar`, `Local`, `Argument`, `Constructed`) that `Placements` read from its parent, because the compiler converts it to the type it lands on. `TypeReader` turns a restriction into a `Syntax::Type`.
- `index/`: `Collector` records one file's `Def`, `Namespace`, `Mixin`, `InstanceVar`, `Alias` and `Constant` entries. `Workspace` holds the lookups. `Loader` indexes in parallel. `MacroText` picks the `{% if flag?/compare_versions %}` branch to index, flags from the host build and versions from the detected Crystal. `Shims` and `EmbeddedShims` handle shims.
- `resolve/`: `Types` resolves a `Syntax::Type` to a `Resolution` (`TypeRef | UnionRef | MetaRef | TypeVar | ProgramRef | Unknown`). `Ancestors`, `Methods`, `Receiver` (types a call from what is written), `Flow` and `Narrowing` (the compiler's `filters.cr` rules), `Unify`, `Render`, `Precision`, `Autocasts` (the type an `OnAutocast` literal converts to: its own type if some accepted type admits it, the one accepted type that needs the conversion, otherwise `Unknown`).
- `check/`: `Suite` runs every rule over a file's `Sites` and returns warnings with a `Check::Rule` code. `Calls` checks calls. `Settled` proves the def set is closed. Other files hold one rule family each (`Cases`, `Returns`, `InstanceVars`, `Generics`, `Paths`, `Controls`, `Abstracts`).
- `server/`: `Loop` is the message loop, `Session` holds all state, `Published` merges syntax, check and compiler diagnostics per URI, `Compiler` runs `crystal build --no-codegen` on save, `Macros` runs the semantic helper, `ResolverCaches` invalidates the type caches.
- `tools/`: `probe`, `score`, `shims_check`, and `semantic` (the helper binary).
- `fibers.cr`: every fiber goes through `Fibers`.

### Invariants

- A type's identity is `Index::Identity = Public | FilePrivate`. Never compare types by name, a file-private type shares its name with others.
- The semantic helper is a separate process that links the compiler. The server never links the compiler and never runs it on the hover or definition path. A failed helper pass keeps the previous results.
- Crystal's version is detected once into `CrystalVersion::Known | Unknown` on the workspace and passed as data. Do not read `Crystal::VERSION` at the point of use.
- `Receiver` memoises a call result per node (`Memos`). An entry is stored only when the frame has no locals and nothing visiting (`Frame#untracked?`), the depth limit was not hit, and the result is not a cycle or too-deep `Unknown`. It is reused only when the stored `Context` matches the current one (`Context#same_as?`). Break any of these and answers depend on what was hovered first.
- Build `Check::Settled` fresh for each check. Every edit drops the receiver's node memos. When an edit changes a file's declarations, `ResolverCaches#invalidate` also clears the type and method caches. A cache that survives a change gives a stale answer.
- A "type A cannot be B" rule fires only when no member of the resolved type fits (`Check::Fit`). A call is typed by the method's body, so a declared return type is an upper bound. The exception is a value with `Precision::Exact` (ivar or class var read, literal).
- An ivar assigned from a call result must be declared with a type in this repo's source. The compiler infers it, heucristic does not, and our own resolution regresses.
- Never test node classes with `any?(A | B)`. A union of classes as a pattern matches everything. Use a block with `is_a?`.
- Never give a visitor overload an alias-typed union restriction. The alias silently swallows other overloads. Inline the union.
- A union of AST node classes is only checked when written inline as a parameter restriction, an `is_a?` argument or a `case` pattern. An alias of one checks nothing anywhere, and a return type, ivar, record field or local typed with one is `Crystal::ASTNode` to the reader. Return a record or a single class instead. Cover inlined lists with the behavioural table in `spec/support/literal_snippets.cr`.
- Update this section in the same change that changes the shape.

## Comments

You never add a comment. Not a doc comment, not a "why" comment, nothing. Only humans write comments, and only to explain why. If code needs a comment saying what it does, rewrite the code. Comments in examples below are teaching notes.

## Principles

### Unknown is a value

The server gives up instead of guessing, and that refusal is a type, not `nil` and not an exception. Never widen an `Unknown` into `Object` or a heuristic. A name-based guess is a feature to add explicitly and label as a guess.

```crystal
# Bad: nil conflates "no annotation" with "not looked up yet"
def type_of(node : Node) : TypeRef?

# Good
def type_of(node : Node) : Resolution # TypeRef | Unknown(reason)
```

### Parse, don't validate

Convert raw data into a typed value once, at the boundary (AST, LSP JSON, `CRYSTAL_PATH`, `shard.yml`, files from disk). Past the boundary nothing re-checks it. A failed parse returns a value the caller must handle, never a default that happens to type-check.

A type restriction is parsed into a type once, so no caller ever reads it as a string:

```crystal
# Bad: the restriction stays a string, so every caller parses it again, and this one misses `Int32 | Nil`
def nilable?(restriction : String) : Bool
  restriction.ends_with?("?")
end

# Good: parsed once, and the compiler makes every caller handle every kind of type
class Named
  getter name : String

  def initialize(@name : String)
  end
end

class Nilable
  getter inner : Type

  def initialize(@inner : Type)
  end
end

class UnionType
  getter members : Array(Type)

  def initialize(@members : Array(Type))
  end
end

alias Type = Named | Nilable | UnionType

def nilable?(type : Type) : Bool
  case type
  in Named     then type.name == "Nil"
  in Nilable   then true
  in UnionType then type.members.any? { |member| nilable?(member) }
  end
end
```

Output from another program is parsed into a value that says whether parsing worked:

```crystal
# Bad: an unparseable version silently becomes a guessed one, and callers can't tell
VERSION  = /\A(\d+)\.(\d+)\.(\d+)\z/
FALLBACK = SemanticVersion.new(1, 22, 2)

def detect_version(raw : String) : SemanticVersion
  match = VERSION.match(raw.strip)
  return FALLBACK unless match

  SemanticVersion.new(match[1].to_i, match[2].to_i, match[3].to_i)
end

# Good: no exceptions, and the failure is a value every caller has to handle
record Unknown, reason : String

VERSION = /\A(\d+)\.(\d+)\.(\d+)\z/

def detect_version(raw : String) : SemanticVersion | Unknown
  match = VERSION.match(raw.strip)
  return Unknown.new("unparseable Crystal version #{raw.inspect}") unless match

  SemanticVersion.new(match[1].to_i, match[2].to_i, match[3].to_i)
end

case version = detect_version(output)
in SemanticVersion then index_with(version)
in Unknown         then skip_version_checks(version.reason)
end
```

Editor JSON is decoded once into a `JSON::Serializable` type, so handlers never touch raw JSON:

```crystal
# Bad: every handler digs through raw JSON, and a missing or wrong field crashes the server
def hover(request : JSON::Any) : String
  line = request["position"]["line"].as_i
  "hover at #{line}"
end

# Good: the shape is a type, and a malformed request is a value
struct Position
  include JSON::Serializable

  getter line : Int32
  getter character : Int32
end

struct HoverParams
  include JSON::Serializable

  getter position : Position
end

record Malformed, error : JSON::ParseException

def decode(body : String) : HoverParams | Malformed
  HoverParams.from_json(body)
rescue error : JSON::ParseException
  Malformed.new(error)
end

case params = decode(body)
in HoverParams then "hover at #{params.position.line}"
in Malformed   then "malformed request: #{params.error.message}"
end
```

### Make invalid states unrepresentable

If a field only means something in some states, or two fields can contradict, use a type per state. No sentinel values: an empty string, `0` or `-1` for "none", and no `|| ""` or `|| 0` defaults when reading an optional value. Model the absent case as its own type in a union (`Index::TopLevel`, `Builtins::NoSuperclass`). Model awkward real states too: a file that failed to parse and a require that resolved to nothing are ordinary entries.

```crystal
# Bad
record Def, name : String, return_type : Syntax::Type?, class_method : Bool, receiver : String?

# Good
record InstanceDef, name : String, signature : Signature
record ClassDef, name : String, receiver : Syntax::Type, signature : Signature
alias Def = InstanceDef | ClassDef
```

### Errors are values

An exception isn't part of a method's signature, so the compiler can't make a caller handle it. In a fiber, an unhandled exception kills the fiber and nothing else notices. Return a failure as a value instead, so it's in the signature and every caller has to deal with it. The only allowed `raise` is an assertion for a bug in our own logic.

```crystal
# Bad: the signature says String, but it can also raise, and nothing makes the caller handle that
class NotFound < Exception
end

def resolve(required : String) : String
  tried = SEARCH_PATHS.map { |dir| File.join(dir, "#{required}.cr") }.to_a
  found = tried.find { |path| File.exists?(path) }
  raise NotFound.new("can't find #{required}") unless found

  found
end

# Good: the failure is in the signature, so every caller has to handle it
record NotFound, required : String, tried : Array(String)

def resolve(required : String) : String | NotFound
  tried = SEARCH_PATHS.map { |dir| File.join(dir, "#{required}.cr") }.to_a
  tried.find { |path| File.exists?(path) } || NotFound.new(required, tried)
end

case found = resolve("server")
in String   then require_file(found)
in NotFound then report_missing(found.required, found.tried)
end
```

A rescue is only for an API we don't control that has no non-raising form, like `Crystal::Parser` or `JSON.parse`. Code we control never raises for an expected failure: return a value instead.

Put the raising call alone in its own method, with the rescue only wrapping that exact call, so a reader knows exactly which line can fail.

```crystal
# Bad: three lines share the rescue, so it's unclear which one can raise
def parse(source : String, path : String) : Crystal::ASTNode | SyntaxError
  parser = Crystal::Parser.new(source)
  parser.filename = path
  parser.parse
rescue error : Crystal::SyntaxException
  SyntaxError.new(error)
end

# Good: `run` holds only the call that raises
record SyntaxError, error : Crystal::SyntaxException

def parse(source : String, path : String) : Crystal::ASTNode | SyntaxError
  parser = Crystal::Parser.new(source)
  parser.filename = path
  run(parser)
end

def run(parser : Crystal::Parser) : Crystal::ASTNode | SyntaxError
  parser.parse
rescue error : Crystal::SyntaxException
  SyntaxError.new(error)
end
```

Never write a bare `rescue` or `rescue Exception`. A blanket rescue catches our own bugs along with the failure it was meant for, and hides them. Always name the specific class the call documents. The one exception is `Fibers.detach`, which catches everything so a spawned fiber's failure is reported instead of lost. Use a nil-returning stdlib variant (`File.info?`) only where the reason does not matter. `Hash#[]?` and `Channel#receive?` are fine.

### Assertions are a last resort

`.not_nil!`, `.as` casts and `raise "unreachable"` stop the compiler checking. Don't use them. If you must, leave a comment saying why, and verify the why. Pointer casts at a `lib` boundary are fine without one. `.as` on our own types is banned. Before doing so, you should first see if you can re-model the solution to avoid the raise entirely (see "parse, don't validate" above).

Prefer, in order: flow narrowing, restructuring so the case cannot arise, exhaustive `case ... in`. The last resort is raising with a message naming the broken invariant, for corrupt internal state only. Input from outside the process (editor JSON, source text, the filesystem) is parsed, never asserted.

A missing value is usually a real case, not an impossible one. Make it a value the caller handles:

```crystal
# Bad: hovering a name that isn't indexed yet crashes the server
def definition(index : Hash(String, Def), name : String) : Def
  index[name]?.not_nil!
end

# Good: the missing case is in the signature
record NotIndexed, name : String

def definition(index : Hash(String, Def), name : String) : Def | NotIndexed
  index[name]? || NotIndexed.new(name)
end

case found = definition(index, name)
in Def        then show(found)
in NotIndexed then say_not_indexed(found.name)
end
```

A cast usually means the type was thrown away earlier. Keep it instead:

```crystal
# Bad: the hash forgets which key holds which type, so reading it needs a cast that crashes if someone stored "8080"
options = {} of String => String | Int32 | Bool
options["port"] = 8080
port = options["port"].as(Int32)

# Good: each field keeps its type, so there's nothing to cast and storing "8080" doesn't compile
record Options, port : Int32, verbose : Bool

options = Options.new(port: 8080, verbose: false)
port = options.port
```

### Exhaustive `case ... in`

Match enums and unions with `in`, never `when`, so a new variant is a compile error everywhere. Consume a union with `case ... in`, never a chain of `is_a?` checks. A chain of `is_a?` compiles fine when a new variant is added, and the new variant silently falls through to whatever the last branch does.

```crystal
# Bad: add `Macro` to `Declaration` and this still compiles, labelling every macro "constant"
def label(declaration : Declaration) : String
  if declaration.is_a?(Def)
    "def #{declaration.name}"
  elsif declaration.is_a?(Alias)
    "alias #{declaration.name}"
  else
    "constant #{declaration.name}"
  end
end

# Good: add `Macro` to `Declaration` and this stops compiling until it handles it
alias Declaration = Def | Alias | Constant

def label(declaration : Declaration) : String
  case declaration
  in Def      then "def #{declaration.name}"
  in Alias    then "alias #{declaration.name}"
  in Constant then "constant #{declaration.name}"
  end
end
```

A lone `is_a?` is only for a site where one variant matters and the rest are genuinely the same case. Prefer `.private?` over spelling `Visibility::Private`, and symbol autocasting over enum constants. Give the owning type predicates so most callers never touch the union.

Crystal has no sealed classes and abstract structs cannot be exhaustively cased, so model a closed set as an `alias` of a union. Use an abstract struct only for method dispatch.

### Structs for values, classes for mutable state

Immutable values are structs, and `record` when there is no behaviour beyond the fields. Anything mutated in place is a class. A struct with mutable ivars is copied when passed, so the caller never sees the change.

A struct is stack allocated and free per AST node. A class instance per node is GC churn, so hoist it out of the loop. Mutable heap state is long-lived and owned in one place. Constant lists are tuple literals, not arrays.

### No primitives where a type belongs

A `Bool`, `Int`, `String`, `Hash` or `Tuple` carries its meaning only in the author's head. When one stands for a concept, give the concept a type: an enum, a `record` or a union. Then the compiler checks every use and a reader sees what the value means.

A `Bool` that picks behaviour becomes an enum, so the call site says which behaviour it wants:

```crystal
# Bad: a reader of the call has no idea what `true` means
admits?("Int32", "Unknown", true)

def admits?(restriction : String, argument : String, lenient : Bool) : Bool
  argument == restriction || (lenient && argument == "Unknown")
end

# Good
admits?("Int32", "Unknown", :check)

enum Admission
  Overload
  Check
end

def admits?(restriction : String, argument : String, admission : Admission) : Bool
  case admission
  in .overload? then argument == restriction
  in .check?    then argument == restriction || argument == "Unknown"
  end
end
```

Two `Bool`s that only make sense together become one enum. Two Bools give four combinations, and here only three are real:

```crystal
# Bad: `locate("Foo", false, true)` compiles, but searching constants without ancestors means nothing
def locate(name : String, with_ancestors : Bool, constants : Bool) : String
  if constants
    "#{name} anywhere, constants included"
  elsif with_ancestors
    "#{name} in the current namespace and its ancestors"
  else
    "#{name} in the current namespace"
  end
end

# Good: only the three real lookups exist
enum Lookup
  Lexical
  Inherited
  Any
end

def locate(name : String, lookup : Lookup) : String
  case lookup
  in .lexical?   then "#{name} in the current namespace"
  in .inherited? then "#{name} in the current namespace and its ancestors"
  in .any?       then "#{name} anywhere, constants included"
  end
end
```

A key built by joining strings becomes a `record`, so it can't be misspelled or mixed up with another string:

```crystal
# Bad: "src/a.cr:3" and "src/a.cr :3" are different keys, and any string fits
seen = Set(String).new
seen << "#{path}:#{line}"

# Good
record Locus, path : String, line : Int32

seen = Set(Locus).new
seen << Locus.new(path, line)
```

A type name is never a string. Parse it once into `Syntax::Type` (see Parse, don't validate). A type's identity is `Index::Identity`, never its name. A tuple is fine as a multiple return destructured on the spot, but one passed through several methods needs a `record`.

### One module per level

Every file opens with a bare `module Heucristic` and nests one `module` or `class` per segment. Never `module Heucristic::Protocol`, never reference `Heucristic::` inside the app, never `include Heucristic`. Specs and tools sit outside and use `Heucristic::...`.

### No redundant names

A type never repeats its namespace: `Server::Loop`, not `Server::Server`. The file is named after the type.

### One type per file

One top-level type per file, named after it. Split other types into their own file and `require` them. Two exceptions: a sealed union with its variants in a file named after the union (`Resolution`), and a type nested in and scoped to its owner (`Unknown::Reason`).

### Member order inside a type

Nested constants, aliases, records and enums. Then `def self.x`, `initialize`, public instance methods, `protected`, `private`. Nothing interleaved. Private helpers go at the bottom of the private section, not beside their caller. A new public method goes above the first `protected` or `private` def.

### Performance is measured

- Hover and definition on an indexed workspace answer from memory with no parsing and no I/O.
- Every interactive request has a budget and a spec that fails when it is exceeded.
- Hot paths get allocation budgets via `assert_allocates_under`. (TODO: decide) That helper does not exist.
- Indexing a file depends only on that file. Keep a spec that indexes it with and without the rest of the workspace and compares.
- Give collections `initial_capacity:` when the size is known.
- A speed claim needs a number from a real run.

## Concurrency

- The document store is the single source of truth for open buffers and has one writer. `didChange` applies the edit and bumps a revision synchronously, and never waits on analysis.
- A request snapshots the revision it answers for. If the revision moved it returns `ContentModified`. (TODO: decide) This is not implemented.
- Background indexing runs on its own `Fiber::ExecutionContext` and publishes whole immutable index values.
- An unhandled exception in a fiber does not stop the process. Spawn every fiber through `Fibers`, never a bare `spawn`.
- Block variables are shared across fibers spawned in a loop. Pass per-worker state as method parameters, and make the loop body a single method call.

## Testing

- Specs run on in-memory source strings. `index/`, `resolve/` and flow code never touch the filesystem or the protocol.
- Every narrowing rule has a spec with the smallest snippet that exercises it, expecting what `crystal build` says. When in doubt run the compiler and cite the result in the spec name.
- Test fault tolerance with truncated and mid-edit sources: a cursor after `x.`, a missing `end`, an unterminated string. Each must still yield the declarations around the damage.
- Light mutation testing should be used for important cases. (TODO: decide) There is no tool for it.
- Never `sleep` to wait on async work. Use channel-based `await` helpers, and be careful with timeouts on "never arrives" assertions.
- A slow spec usually means the app is slow. Measure with `crystal spec --junit_output <dir>` or `sample <pid>` before working around it in the spec.
- A spec that must index the whole stdlib to hit a bound is a design smell. Split the decision ("is this over the bound?") into an object that takes the bound as a query argument, and test it at a scale of three. Do not add a parameter only specs pass.
