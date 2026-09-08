require "../../spec_helper"

private def lookup(source : String, receiver : String, name : String, arity : Int32) : Array(String)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
  )
  types = Heucristic::Resolve::Types.new(workspace)
  scope = Heucristic::Resolve::Scope::TOP
  resolved = types.resolve(Heucristic::Syntax::Named.new(receiver.split("::"), false), scope)
  Heucristic::Resolve::Methods.new(workspace, types).lookup(resolved, name, arity).map(&.qualified)
end

private def lookup_meta(
  source : String,
  receiver : String,
  name : String,
  arity : Int32,
) : Array(String)
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
  Heucristic::Resolve::Methods.new(workspace, types).lookup(meta, name, arity).map(&.qualified)
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
end
