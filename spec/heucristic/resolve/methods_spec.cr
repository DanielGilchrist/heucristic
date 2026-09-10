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
end
