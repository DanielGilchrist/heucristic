require "../../spec_helper"

private def ancestors_of(source : String, name : String) : String
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  text = Heucristic::Document::Text.new(source)
  workspace.update(Heucristic::Index::Collector.collect("a.cr", text, tree))
  chain = Heucristic::Resolve::Types.new(workspace).ancestors(name)
  chain.is_a?(Heucristic::Resolve::Unknown) ? chain.to_s : chain.join(", ")
end

describe Heucristic::Resolve::Ancestors do
  it "lists includes most recent first, then the superclass chain" do
    source = <<-CR
      module Walk; end
      module Talk; end
      class Animal; end
      class Dog < Animal
        include Walk
        include Talk
      end
      CR
    ancestors_of(source, "Dog").should eq("Talk, Walk, Animal, Reference, Object")
  end

  it "follows includes of the ancestors and drops repeats" do
    source = <<-CR
      module Base; end
      module Mixed
        include Base
      end
      class Thing
        include Mixed
        include Base
      end
      CR
    ancestors_of(source, "Thing").should eq("Base, Mixed, Reference, Object")
  end

  it "gives a struct, an enum and a module their implicit parents" do
    source = <<-CR
      struct Point; end
      enum Colour; end
      module Helper; end
      CR
    ancestors_of(source, "Point").should eq("Struct, Value, Object")
    ancestors_of(source, "Colour").should eq("Enum, Value, Object")
    ancestors_of(source, "Helper").should eq("")
  end

  it "merges includes across reopenings and resolves parents from the type's own namespace" do
    source = <<-CR
      module Outer
        module Shared; end
        class Thing; end
        class Thing
          include Shared
        end
      end
      CR
    ancestors_of(source, "Outer::Thing").should eq("Outer::Shared, Reference, Object")
  end

  it "knows the compiler's builtin hierarchy" do
    ancestors_of("", "Int32").should eq("Int, Number, Value, Object")
    ancestors_of("", "String").should eq("Reference, Object")
  end

  it "refuses a chain with an unresolved parent instead of truncating it" do
    ancestors_of("class Thing < Missing; end", "Thing").should eq(
      "unknown (unresolved name: Missing)"
    )
    ancestors_of("class Thing\n  include Missing\nend", "Thing").should eq(
      "unknown (unresolved name: Missing)"
    )
  end

  it "refuses an inheritance cycle" do
    source = <<-CR
      module A
        include B
      end
      module B
        include A
      end
      CR
    ancestors_of(source, "A").should eq("unknown (cycle: A)")
  end

  it "reports an unknown type" do
    ancestors_of("", "Nope").should eq("unknown (unresolved name: Nope)")
  end
end
