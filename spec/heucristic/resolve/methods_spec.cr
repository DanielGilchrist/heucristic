require "../../spec_helper"

private def lookup(source : String, receiver : String, name : String, arity : Int32) : Array(String)
  call = Heucristic::Resolve::Methods::Call.new(name, arity, false)
  lookup(source, receiver, call).map(&.qualified)
end

private def lookup(
  source : String,
  receiver : String,
  call : Heucristic::Resolve::Methods::Call,
) : Array(Heucristic::Index::Def)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
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
  call = Heucristic::Resolve::Methods::Call.new(name, arity, false)
  lookup_meta(source, receiver, call).map(&.qualified)
end

private def lookup_meta(
  source : String,
  receiver : String,
  call : Heucristic::Resolve::Methods::Call,
) : Array(Heucristic::Index::Def)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
  )
  types = Heucristic::Resolve::Types.new(workspace)
  meta = Heucristic::Resolve::MetaRef.new(
    Heucristic::Resolve::TypeRef.new(receiver, Array(Heucristic::Resolve::Resolution).new)
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
        Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    object = Heucristic::Resolve::TypeRef.of(:object)
    none = Array(Heucristic::Resolve::Resolution).new
    bindings = Array(Heucristic::Resolve::Binding).new
    from_a = Heucristic::Resolve::Methods::Call.new(
      "with_roots", 0, true, none, Array(String).new, bindings, true, "a.cr"
    )
    methods.lookup(object, from_a).map(&.path).should eq(["a.cr"])
    from_c = Heucristic::Resolve::Methods::Call.new(
      "with_roots", 0, true, none, Array(String).new, bindings, true, "c.cr"
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
        Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    targets = {
      Heucristic::Index::MacroTarget::Main  => Set{"/p/src/a.cr", "/p/src/main.cr"},
      Heucristic::Index::MacroTarget::Loose => Set{"/p/bench/b.cr"},
    }
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, "/p", Array(String).new))
    foo = Heucristic::Resolve::TypeRef.new("Foo", Array(Heucristic::Resolve::Resolution).new)
    methods.named_on(foo, "bar", "/p/src/main.cr").map(&.path).should eq(["/p/src/a.cr"])
    methods.named_on(foo, "bar", "/p/bench/b.cr").map(&.path).should eq(["/p/bench/b.cr"])
    methods.named_on(foo, "bar", "/p/script/other.cr").map(&.path).size.should eq(2)
  end
end

describe Heucristic::Resolve::Methods, "file-private types" do
  it "answers a file-private type's methods only from the calling file" do
    workspace = Heucristic::Index::Workspace.new
    {
      {"a.cr", "private record Ends, local : Int32\n"},
      {"b.cr", "private record Ends, local : String\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    ends = Heucristic::Resolve::TypeRef.new("Ends", Array(Heucristic::Resolve::Resolution).new)
    methods.named_on(ends, "local", "a.cr").map(&.path).should eq(["a.cr"])
    methods.named_on(ends, "local", "b.cr").map(&.path).should eq(["b.cr"])
    methods.named_on(ends, "local").map(&.path).should eq(["a.cr", "b.cr"])
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
      Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
    )
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    list = Heucristic::Resolve::TypeRef.new("List", Array(Heucristic::Resolve::Resolution).new)

    with_block = methods.lookup(list, Heucristic::Resolve::Methods::Call.new("each", 0, true))
    without = methods.lookup(list, Heucristic::Resolve::Methods::Call.new("each", 0, false))
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
    float = Heucristic::Resolve::TypeRef.new("Float64", Array(Heucristic::Resolve::Resolution).new)
    unknown = Heucristic::Resolve::Unknown.new(:no_annotation, "x")
    floats = [float, float] of Heucristic::Resolve::Resolution
    unknowns = [unknown, unknown] of Heucristic::Resolve::Resolution
    typed = Heucristic::Resolve::Methods::Call.new("min", 2, false, floats)
    untyped = Heucristic::Resolve::Methods::Call.new("min", 2, false, unknowns)
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
    string = Heucristic::Resolve::TypeRef.new("String", Array(Heucristic::Resolve::Resolution).new)
    one = Heucristic::Resolve::Methods::Call.new(
      "glob", 1, false, [string] of Heucristic::Resolve::Resolution
    )
    hidden = Heucristic::Resolve::Methods::Call.new(
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
    string = Heucristic::Resolve::TypeRef.new("String", Array(Heucristic::Resolve::Resolution).new)
    symbol = Heucristic::Resolve::TypeRef.new("Symbol", Array(Heucristic::Resolve::Resolution).new)
    call = Heucristic::Resolve::Methods::Call.new(
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
    int = Heucristic::Resolve::TypeRef.new("Int32", Array(Heucristic::Resolve::Resolution).new)
    by_name = Heucristic::Resolve::Methods::Call.new(
      "new", 0, false, Array(Heucristic::Resolve::Resolution).new, ["x", "y"]
    )
    mixed = Heucristic::Resolve::Methods::Call.new(
      "new", 1, false, [int] of Heucristic::Resolve::Resolution, ["y", "label"]
    )
    missing = Heucristic::Resolve::Methods::Call.new(
      "new", 0, false, Array(Heucristic::Resolve::Resolution).new, ["x"]
    )
    too_many = Heucristic::Resolve::Methods::Call.new(
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
      {"/p/src/a.cr", "abstract class Shape\nend\n\nclass Circle < Shape\nend\n"},
      {"/p/src/extra.cr", "class Square < Shape\nend\n"},
    }.each do |path, source|
      tree = Heucristic::Syntax.parse(source, path)
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      workspace.update(
        Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
      )
    end
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    targets = {Heucristic::Index::MacroTarget::Main => Set{"/p/src/a.cr", "/p/src/main.cr"}}
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, "/p", Array(String).new))
    shape = Heucristic::Resolve::TypeRef.new("Shape", Array(Heucristic::Resolve::Resolution).new)
    methods.virtual_receivers(shape, "/p/src/main.cr").map(&.to_s).should eq(["Circle"])
    methods.virtual_receivers(shape, nil).map(&.to_s).sort!.should eq(["Circle", "Square"])
    metaclass = Heucristic::Resolve::MetaRef.new(shape)
    methods.virtual_receivers(metaclass, nil).map(&.to_s).sort!.should eq(
      ["Circle.class", "Square.class"]
    )
  end

  it "treats the compiler's abstract builtins as virtual over their builtin subtypes" do
    workspace = Heucristic::Index::Workspace.new
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    float = Heucristic::Resolve::TypeRef.new("Float", Array(Heucristic::Resolve::Resolution).new)
    methods.abstract_class?("Float").should be_true
    methods.virtual_receivers(float, nil).map(&.to_s).sort!.should eq(["Float32", "Float64"])
  end
end
