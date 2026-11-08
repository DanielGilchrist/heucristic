require "../../spec_helper"

private def lookup(source : String, receiver : String, name : String, arity : Int32) : Array(String)
  call = call_shape(name, arity, false)
  lookup(source, receiver, call).map(&.qualified)
end

private def lookup(
  source : String,
  receiver : String,
  call : Heucristic::Resolve::Methods::CallShape,
) : Array(Heucristic::Index::Def)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect(
      "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
    )
  )
  types = Heucristic::Resolve::Types.new(workspace)
  scope = Heucristic::Resolve::Scope::TOP
  resolved = types.resolve(Heucristic::Syntax::Named.new(receiver.split("::"), false), scope)
  Heucristic::Resolve::Methods.new(workspace, types).lookup(resolved, call)
end

private def lookup_meta(
  source : String,
  receiver : String,
  name : String,
  arity : Int32,
) : Array(String)
  call = call_shape(name, arity, false)
  lookup_meta(source, receiver, call).map(&.qualified)
end

private def lookup_meta(
  source : String,
  receiver : String,
  call : Heucristic::Resolve::Methods::CallShape,
) : Array(Heucristic::Index::Def)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect(
      "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
    )
  )
  types = Heucristic::Resolve::Types.new(workspace)
  meta = Heucristic::Resolve::MetaRef.new(
    type_ref(receiver)
  )
  Heucristic::Resolve::Methods.new(workspace, types).lookup(meta, call)
end

describe Heucristic::Resolve::Methods, "top-level defs" do
  it "prefers the calling file's private def over a public one of the same name elsewhere" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"a.cr", "private def with_roots(& : Int32 ->) : Nil\nend\n"},
      {"b.cr", "def with_roots(& : String ->) : Nil\nend\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    object = Heucristic::Resolve::TypeRef.of(:object)
    none = Array(Heucristic::Resolve::Resolution).new
    from_a = call_shape(
      "with_roots", 0, true, none, Array(String).new, true, "a.cr"
    )
    methods.lookup(object, from_a).map(&.path).should eq(["a.cr"])
    from_c = call_shape(
      "with_roots", 0, true, none, Array(String).new, true, "c.cr"
    )
    methods.lookup(object, from_c).map(&.path).should eq(["b.cr"])
  end
end

describe Heucristic::Resolve::Methods, "compiled targets" do
  it "answers a project def only to callers compiled in a shared target" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"/p/src/a.cr", "class Foo\n  def bar : Int32\n    1\n  end\nend\n"},
      {"/p/bench/b.cr", "class Foo\n  def bar : String\n    \"x\"\n  end\nend\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    targets = {
      Heucristic::Index::MacroTarget::Main  => Set{"/p/src/a.cr", "/p/src/main.cr"},
      Heucristic::Index::MacroTarget::Loose => Set{"/p/bench/b.cr"},
    }
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, Array(String).new))
    foo = type_ref("Foo")
    methods.named_on(foo, "bar", "/p/src/main.cr").map(&.path).should eq(["/p/src/a.cr"])
    methods.named_on(foo, "bar", "/p/bench/b.cr").map(&.path).should eq(["/p/bench/b.cr"])
    methods.named_on(foo, "bar", "/p/script/other.cr").map(&.path).size.should eq(2)
  end
end

private def hidden_meta(path : String) : Heucristic::Resolve::MetaRef
  Heucristic::Resolve::MetaRef.new(type_ref(private_type("Hidden", path)))
end

private def builds(methods : Heucristic::Resolve::Methods, caller_path : String) : Array(String)
  methods.named_on(hidden_meta(caller_path), "build", caller_path).map(&.signature)
end

private def private_generated_methods(*declared : {String, String}) : Heucristic::Resolve::Methods
  workspace = Heucristic::Index::Workspace.new
  declared.each do |path, _|
    source = "private struct Hidden\nend\n"
    tree = Heucristic::Syntax.parse(source, path)
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    workspace.update(
      Heucristic::Index::Collector.collect(
        path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
      )
    )
  end
  generated = Heucristic::Index::MacroTarget::Spec.generated_path
  source = declared.map { |_, type| "struct Hidden\n  def self.build : #{type}\n  end\nend\n" }.join
  sites = declared.map_with_index do |(path, _), index|
    Heucristic::Index::MacroSite.new(
      index * 4 + 2, "Hidden", "build", true, "make", nil, nil, nil, nil, nil, path
    )
  end.to_a
  tree = Heucristic::Syntax.parse(source, generated)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  text = Heucristic::Document::Text.new(source)
  collected = Heucristic::Index::Collector.collect(generated, text, tree, SPEC_CRYSTAL)
  shims = Heucristic::Index::Shims.new
  loaded = Heucristic::Index::LoadedFiles.new(declared.map(&.[0]).to_set, Array(String).new)
  workspace.update(Heucristic::Index::Generated.merge(
    collected, sites, Array(Heucristic::Index::Reopening).new, workspace, shims, loaded
  ))
  Heucristic::Resolve::Methods.new(workspace, Heucristic::Resolve::Types.new(workspace))
end

describe Heucristic::Resolve::Methods, "file-private types" do
  it "answers a file-private type's methods only from its own file" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"a.cr", "private record Ends, local : Int32\n"},
      {"b.cr", "private record Ends, local : String\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    ["a.cr", "b.cr"].each do |path|
      ends = type_ref(private_type("Ends", path))
      methods.named_on(ends, "local").map(&.path).should eq([path])
    end
    public_ends = type_ref("Ends")
    methods.named_on(public_ends, "local").should be_empty
  end

  it "answers a macro-generated def of a file-private type from the declaring file" do
    methods = private_generated_methods({"a.cr", "Int32"})
    builds(methods, "a.cr").should eq(["def self.build : Int32"])
  end

  it "builds the default constructor of same-named file-private types in each file" do
    methods = private_generated_methods({"a.cr", "Int32"}, {"b.cr", "String"})
    ["a.cr", "b.cr"].each do |caller_path|
      found = methods.named_on(hidden_meta(caller_path), "new", caller_path)
      found.map(&.path).should eq([caller_path])
    end
  end

  it "keeps the generated defs of same-named file-private types apart" do
    methods = private_generated_methods({"a.cr", "Int32"}, {"b.cr", "String"})
    builds(methods, "a.cr").should eq(["def self.build : Int32"])
    builds(methods, "b.cr").should eq(["def self.build : String"])
  end
end

describe Heucristic::Resolve::Methods do
  source = <<-CR
    module Greets
      def greet(name : String) : String
        name
      end
    end

    class Animal
      def speak : String
        "..."
      end

      def greet(name : String, times : Int32) : String
        name
      end
    end

    class Dog < Animal
      include Greets

      def initialize(@name : String) : Nil
      end

      def speak : String
        "woof"
      end

      def self.stray : Dog
        new("?")
      end
    end
    CR

  it "prefers the type's own def over an ancestor's" do
    lookup(source, "Dog", "speak", 0).should eq(["Dog#speak"])
  end

  it "walks the ancestors in order and stops at the first level with a match" do
    lookup(source, "Dog", "greet", 1).should eq(["Greets#greet"])
    lookup(source, "Dog", "greet", 2).should eq(["Animal#greet"])
  end

  it "returns nothing when no def fits" do
    lookup(source, "Dog", "fetch", 0).should be_empty
    lookup(source, "Dog", "speak", 3).should be_empty
  end

  it "finds class methods on the metaclass and maps new to initialize" do
    lookup_meta(source, "Dog", "stray", 0).should eq(["Dog.stray"])
    lookup_meta(source, "Dog", "new", 1).should eq(["Dog#initialize"])
    lookup_meta(source, "Dog", "speak", 0).should be_empty
  end

  it "finds instance defs of an extended module on the metaclass, including extend self" do
    source = <<-CR
      module Helpers
        def helper : Int32
        end
      end

      module Fibers
        extend self
        extend Helpers

        def detach(name : String) : Nil
        end
      end

      class Base
        extend Helpers
      end

      class Child < Base
      end
      CR
    lookup_meta(source, "Fibers", "detach", 1).should eq(["Fibers#detach"])
    lookup_meta(source, "Fibers", "helper", 0).should eq(["Helpers#helper"])
    lookup_meta(source, "Child", "helper", 0).should eq(["Helpers#helper"])
    lookup(source, "Fibers", "detach", 1).should eq(["Fibers#detach"])
  end

  it "never reaches the new of an extended module (compiler: inherited initialize wins)" do
    source = <<-CR
      module Factory
        def new(x : Int32) : String
        end
      end

      class Parent
        def initialize(x : Int32)
        end
      end

      class Child < Parent
        extend Factory
      end

      class Lone
        extend Factory
      end
      CR
    lookup_meta(source, "Child", "new", 1).should eq(["Parent#initialize"])
    lookup_meta(source, "Lone", "new", 1).should be_empty
  end

  it "does not reach an extended new on a class with no initialize (compiler: Lone)" do
    source = <<-CR
      module Factory
        def new : String
        end
      end

      class Lone
        extend Factory
      end
      CR
    lookup_meta(source, "Lone", "new", 0).should eq(["Lone.new"])
  end

  it "never reaches the allocate of an extended module (the compiler's primitive wins)" do
    source = <<-CR
      module Pool
        def allocate : Int32
        end
      end

      class Lone
        extend Pool
      end

      class Own
        extend Pool

        def self.allocate : Float64
        end
      end
      CR
    lookup_meta(source, "Lone", "allocate", 0).should be_empty
    lookup_meta(source, "Own", "allocate", 0).should eq(["Own.allocate"])
  end

  it "reaches an allocate only on the class that defines it, or on a module" do
    source = <<-CR
      class Par
        def self.allocate : Int32
        end
      end

      class Chi < Par
      end

      module SelfEx
        extend self

        def allocate : String
        end
      end
      CR
    lookup_meta(source, "Par", "allocate", 0).should eq(["Par.allocate"])
    lookup_meta(source, "Chi", "allocate", 0).should be_empty
    lookup_meta(source, "SelfEx", "allocate", 0).should eq(["SelfEx#allocate"])
  end

  it "does not extend a class's metaclass with the extend self of a module it includes" do
    source = <<-CR
      module Checks
        extend self
      end

      class Operation
        include Checks

        def run : Nil
        end
      end

      class Save < Operation
      end
      CR
    lookup_meta(source, "Save", "run", 0).should be_empty
    lookup_meta(source, "Operation", "run", 0).should be_empty
  end

  it "separates a yielding def from its block-less overload" do
    source = <<-CR
      class List
        def each : Int32
        end

        def each(& : Int32 ->) : Nil
        end
      end
      CR
    tree = Heucristic::Syntax.parse(source, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)
    workspace = Heucristic::Index::Workspace.new
    workspace.update(
      Heucristic::Index::Collector.collect(
        "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
      )
    )
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    list = type_ref("List")

    with_block = methods.lookup(list, call_shape("each", 0, true))
    without = methods.lookup(list, call_shape("each", 0, false))
    with_block.map(&.signature).should eq(["def each(& : Int32 ->) : Nil"])
    without.map(&.signature).should eq(["def each : Int32"])
  end

  it "prefers an overload with restricted parameters over an unrestricted one" do
    source = <<-CR
      class Calc
        def min(a : Float64, b : Float64) : Float64
        end

        def min(a, b)
        end

        def min(a : Float32, b : Float32) : Float32
        end
      end
      CR
    float = type_ref("Float64")
    unknown = Heucristic::Resolve::Unknown.new(:no_annotation, "x")
    floats = [float, float] of Heucristic::Resolve::Resolution
    unknowns = [unknown, unknown] of Heucristic::Resolve::Resolution
    typed = call_shape("min", 2, false, floats)
    untyped = call_shape("min", 2, false, unknowns)
    lookup(source, "Calc", typed).map(&.signature).should eq(
      ["def min(a : Float64, b : Float64) : Float64"]
    )
    lookup(source, "Calc", untyped).size.should eq(3)
  end

  it "matches splat and keyword-only parameters the way the compiler does" do
    source = <<-CR
      class Dir
        def self.glob(*patterns : String, match : Int32 = 0, follow : Bool = false) : Array(String)
        end

        def self.glob(patterns : Array(String), match : Int32 = 0) : Array(String)
        end

        def self.glob(*patterns : String, hidden : Bool, follow : Bool = false) : Array(Int32)
        end
      end
      CR
    string = type_ref("String")
    one = call_shape(
      "glob", 1, false, [string] of Heucristic::Resolve::Resolution
    )
    hidden = call_shape(
      "glob", 1, false, [string] of Heucristic::Resolve::Resolution, ["hidden"]
    )
    lookup_meta(source, "Dir", one).map(&.return_type.to_s).should eq(["Array(String)"])
    lookup_meta(source, "Dir", hidden).map(&.return_type.to_s).should eq(["Array(Int32)"])
  end

  it "admits a symbol literal for an enum parameter, as the compiler autocasts it" do
    source = <<-CR
      enum Origin
        Declared
        Assigned
      end

      class Store
        def record(name : String, origin : Origin) : Nil
        end

        def record(name : String, origin : String) : String
        end
      end
      CR
    string = type_ref("String")
    symbol = type_ref("Symbol")
    call = call_shape(
      "record", 2, false, [string, symbol] of Heucristic::Resolve::Resolution
    )
    lookup(source, "Store", call).map(&.signature).should eq(
      ["def record(name : String, origin : Origin) : Nil"]
    )
  end

  it "lets named arguments satisfy positional parameters, as record constructors are called" do
    source = <<-CR
      class Point
        def initialize(x : Int32, y : Int32, label : String = "p") : Nil
        end
      end
      CR
    int = type_ref("Int32")
    by_name = call_shape(
      "new", 0, false, Array(Heucristic::Resolve::Resolution).new, ["x", "y"]
    )
    mixed = call_shape(
      "new", 1, false, [int] of Heucristic::Resolve::Resolution, ["y", "label"]
    )
    missing = call_shape(
      "new", 0, false, Array(Heucristic::Resolve::Resolution).new, ["x"]
    )
    too_many = call_shape(
      "new", 3, false, [int, int, int] of Heucristic::Resolve::Resolution, ["x"]
    )
    lookup_meta(source, "Point", by_name).size.should eq(1)
    lookup_meta(source, "Point", mixed).size.should eq(1)
    lookup_meta(source, "Point", missing).should be_empty
    lookup_meta(source, "Point", too_many).should be_empty
  end
end

describe Heucristic::Resolve::Methods, "virtual receivers" do
  it "dispatches over the concrete subclasses a caller's target loads" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"/p/src/extra.cr", "class Square < Shape\nend\n"},
      {"/p/src/a.cr", "abstract class Shape\nend\n\nclass Circle < Shape\nend\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    targets = {Heucristic::Index::MacroTarget::Main => Set{"/p/src/a.cr", "/p/src/main.cr"}}
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, Array(String).new))
    shape = type_ref("Shape")
    methods.virtual_receivers(shape, "/p/src/main.cr").map(&.to_s).should eq(["Circle"])
    methods.virtual_receivers(shape, nil).map(&.to_s).should eq(["Circle", "Square"])
    metaclass = Heucristic::Resolve::MetaRef.new(shape)
    methods.virtual_receivers(metaclass, nil).map(&.to_s).should eq(
      ["Circle.class", "Square.class"]
    )
  end

  it "treats the compiler's abstract builtins as virtual over their builtin subtypes" do
    workspace = Heucristic::Index::Workspace.new
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    float = type_ref("Float")
    methods.abstract_class?(public_type("Float")).should be_true
    methods.virtual_receivers(float, nil).map(&.to_s).should eq(["Float32", "Float64"])
  end
end

private def platform_source(handle : String) : String
  <<-CR
    module System
      def self.handle : #{handle}
      end
    end

    lib LibC
      struct Limit
      end
    end
    CR
end

describe Heucristic::Resolve::Methods, "loaded files" do
  it "answers only from the declaration a caller's target loads, default constructors too" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"/std/unix.cr", platform_source("Int32")},
      {"/std/win32.cr", platform_source("UInt64")},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    targets = {Heucristic::Index::MacroTarget::Main => Set{"/p/src/main.cr", "/std/unix.cr"}}
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, Array(String).new))
    system = Heucristic::Resolve::MetaRef.new(type_ref("System"))
    methods.named_on(system, "handle", "/p/src/main.cr").map(&.path).should eq(["/std/unix.cr"])
    limit = Heucristic::Resolve::MetaRef.new(type_ref("LibC::Limit"))
    methods.named_on(limit, "new", "/p/src/main.cr").map(&.path).should eq(["/std/unix.cr"])
  end
end

describe Heucristic::Resolve::Methods, "new next to initialize" do
  source = <<-CR
    class Handler
      def initialize(dir : String, @flag : Bool = true)
      end

      def self.new(dir : String, flag = true)
      end
    end
    CR

  it "keeps initialize beside an explicit self.new with unrestricted parameters" do
    call = call_shape("new", 1, false)
    lines = lookup_meta(source, "Handler", call).map(&.name_span.start_line)

    lines.should contain(1)
  end
end

describe Heucristic::Resolve::Methods, "new on a subclass with its own initialize" do
  source = <<-CR
    class Parent
      def self.new(x : Int32)
      end
    end

    class Child < Parent
      def initialize(x)
      end
    end
    CR

  it "picks the closer initialize over an inherited explicit self.new" do
    call = call_shape("new", 1, false)
    found = lookup_meta(source, "Child", call)

    found.map(&.qualified).should eq(["Child#initialize"])
  end
end

describe Heucristic::Resolve::Methods, "include and extend order" do
  it "finds the def of the module included last" do
    source = <<-CR
      module L; def f : Int32; 1; end; end
      module R; def f : String; "r"; end; end
      class C
        include R
        include L
      end
      CR
    lookup(source, "C", "f", 0).should eq(["L#f"])
  end

  it "keeps the first include of a module repeated later (include X, Y, X finds Y)" do
    source = <<-CR
      module X; def f : Int32; 1; end; end
      module Y; def f : String; "y"; end; end
      class C
        include X
        include Y
        include X
      end
      CR
    lookup(source, "C", "f", 0).should eq(["Y#f"])
  end

  it "finds the class method of the module extended last" do
    source = <<-CR
      module X; def f : Int32; 1; end; end
      module Y; def f : String; "y"; end; end
      class C
        extend X
        extend Y
      end
      CR
    lookup_meta(source, "C", "f", 0).should eq(["Y#f"])
  end

  it "keeps the first extend of a module repeated later (extend X, Y, X finds Y)" do
    source = <<-CR
      module X; def f : Int32; 1; end; end
      module Y; def f : String; "y"; end; end
      class C
        extend X
        extend Y
        extend X
      end
      CR
    lookup_meta(source, "C", "f", 0).should eq(["Y#f"])
  end

  it "skips an extended module whose def rejects the argument for an earlier one that accepts it" do
    source = <<-CR
      class Buffer
      end
      module Base
        def bytes(count : Int32 = 16) : String
          "b"
        end
      end
      module Secure
        extend Base
        extend self

        def bytes(buffer : Buffer) : Nil
        end
      end
      CR
    count = Heucristic::Resolve::TypeRef.of(:int32)
    arguments = [count] of Heucristic::Resolve::Resolution
    call = call_shape("bytes", 1, false, arguments)
    lookup_meta(source, "Secure", call).map(&.qualified).should eq(["Base#bytes"])
  end

  it "reports both defs when extends in different files do not say which came last" do
    files = [
      {"a.cr", "module X; def f : Int32; 1; end; end\nclass C\n  extend X\nend\n"},
      {"c.cr", "module Y; def f : String; \"y\"; end; end\n"},
      {"b.cr", "class C\n  extend Y\nend\n"},
    ]
    workspace = Heucristic::Index::Workspace.new
    files.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    meta = Heucristic::Resolve::MetaRef.new(
      type_ref("C")
    )
    call = call_shape("f", 0, false)
    found = Heucristic::Resolve::Methods.new(workspace, types).lookup(meta, call)
    found.map(&.qualified).sort!.should eq(["X#f", "Y#f"])
  end
end

describe Heucristic::Resolve::Methods, "missing" do
  it "names the unknown include order instead of claiming the method does not exist" do
    sources = {
      "mods.cr" => "module A\n  def f; end\nend\nmodule B\n  def f; end\nend\n",
      "a.cr"    => "class C\n  include A\nend\n",
      "b.cr"    => "class C\n  include B\nend\n",
    }
    workspace = Heucristic::Index::Workspace.new
    sources.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(
          path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    receiver = type_ref("C")
    answer = Heucristic::Resolve::Methods.new(workspace, types).missing("f", receiver)
    answer.detail.should contain("unknown order")
    answer.reason.ambiguous?.should be_true
  end
end

describe Heucristic::Resolve::Methods, "dispatch on union arguments" do
  source = <<-CR
    class Base
      def same(other) : Int32
      end
    end

    module Twice
      def same(other : Text) : Symbol
      end
    end

    class Text < Base
      include Twice

      def same(other : Text) : Bool
      end
    end

    class Blank
    end
    CR

  it "lists each member's overload and the ancestor overloads up to full coverage" do
    tree = Heucristic::Syntax.parse(source, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    workspace = Heucristic::Index::Workspace.new
    workspace.update(
      Heucristic::Index::Collector.collect(
        "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
      )
    )
    types = Heucristic::Resolve::Types.new(workspace)
    text = type_ref("Text")
    blank = type_ref("Blank")
    either = Heucristic::Resolve::UnionRef.new([text, blank] of Heucristic::Resolve::Resolution)
    call = call_shape(
      "same", 1, false, [either] of Heucristic::Resolve::Resolution
    )
    found = Heucristic::Resolve::Methods.new(workspace, types).dispatch(text, call)
    found.map(&.qualified).sort!.should eq(["Base#same", "Text#same", "Twice#same"])
  end
end
