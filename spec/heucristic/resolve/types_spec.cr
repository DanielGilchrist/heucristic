require "../../spec_helper"

private def workspace(source : String) : Heucristic::Index::Workspace
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  text = Heucristic::Document::Text.new(source)
  workspace.update(Heucristic::Index::Collector.collect("a.cr", text, tree))
  workspace
end

private def restriction(source : String) : Heucristic::Syntax::Type
  tree = Heucristic::Syntax.parse("def f(x : #{source}); end", "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::Def)

  node = tree.args[0].restriction
  raise "missing restriction" unless node
  type = Heucristic::Syntax::TypeReader.read(node)
  raise "unsupported restriction" unless type.is_a?(Heucristic::Syntax::Type)

  type
end

private def resolve(
  workspace : Heucristic::Index::Workspace,
  source : String,
  namespace : String? = nil,
  type_vars : Array(String) = Array(String).new,
) : String
  scope = Heucristic::Resolve::Scope.new(namespace || Heucristic::Index::TopLevel.new, type_vars)
  Heucristic::Resolve::Types.new(workspace).resolve(restriction(source), scope).to_s
end

describe Heucristic::Resolve::Types do
  source = <<-CR
    module Outer
      class Thing
      end

      module Inner
        class Thing
        end

        class Deep
          alias Alias = Thing
        end
      end

      alias Pair = Tuple(Int32, Int32)
      alias Loop = Loop
    end

    class Thing
    end
    CR
  ws = workspace(source)

  it "prefers the innermost enclosing namespace" do
    resolve(ws, "Thing", "Outer::Inner::Deep").should eq("Outer::Inner::Thing")
    resolve(ws, "Thing", "Outer").should eq("Outer::Thing")
    resolve(ws, "Thing").should eq("Thing")
  end

  it "walks the rest of a path from the namespace that owns its first segment" do
    resolve(ws, "Inner::Thing", "Outer::Inner::Deep").should eq("Outer::Inner::Thing")
    resolve(ws, "Outer::Thing", "Outer::Inner").should eq("Outer::Thing")
  end

  it "starts at the top level for a global path" do
    resolve(ws, "::Thing", "Outer::Inner").should eq("Thing")
  end

  it "reports a name it cannot find" do
    resolve(ws, "Missing", "Outer").should eq("unknown (unresolved name: Missing)")
    resolve(ws, "Outer::Missing").should eq(
      "unknown (unresolved name: Outer::Missing)"
    )
  end

  it "chases an alias from the alias's own namespace" do
    resolve(ws, "Alias", "Outer::Inner::Deep").should eq("Outer::Inner::Thing")
    resolve(ws, "Pair", "Outer").should eq("Tuple(Int32, Int32)")
  end

  it "refuses an alias cycle" do
    resolve(ws, "Loop", "Outer").should eq("unknown (cycle: Outer::Loop)")
  end

  it "knows the types the compiler creates without source" do
    resolve(ws, "Int32").should eq("Int32")
    resolve(ws, "Hash(String, Array(Thing))", "Outer").should eq(
      "Hash(String, Array(Outer::Thing))"
    )
  end

  it "does not let a builtin shadow a nested name" do
    resolve(ws, "Outer::Int32").should eq("unknown (unresolved name: Outer::Int32)")
  end

  it "expands the nilable shorthand to a union with Nil" do
    resolve(ws, "Thing?", "Outer").should eq("Outer::Thing | Nil")
  end

  it "keeps a type variable argument as the variable itself" do
    resolve(ws, "Array(T)", "Outer", ["T"]).should eq("Array(T)")
  end

  it "resolves a type variable in scope to itself" do
    resolve(ws, "T", "Outer", ["T"]).should eq("T")
  end

  it "resolves self to the enclosing type" do
    resolve(ws, "self", "Outer::Thing").should eq("Outer::Thing")
    resolve(ws, "self").should eq("unknown (unsupported: self outside a type)")
  end

  it "resolves a metaclass" do
    resolve(ws, "Thing.class", "Outer").should eq("Outer::Thing.class")
  end

  it "gives up on a union with an unresolved member" do
    resolve(ws, "Thing | Missing", "Outer").should eq("unknown (unresolved name: Missing)")
  end

  it "labels the restriction kinds it does not handle yet" do
    resolve(ws, "typeof(1)").should eq("unknown (unsupported: typeof(1))")
    resolve(ws, "NamedTuple(a: Int32)").should eq(
      "unknown (unsupported: named type arguments in NamedTuple(a: Int32))"
    )
    resolve(ws, "StaticArray(UInt8, 4)").should eq(
      "StaticArray(UInt8, unknown (non type argument: 4))"
    )
  end

  it "treats a missing restriction as no annotation" do
    resolver = Heucristic::Resolve::Types.new(ws)
    resolver.resolve(Heucristic::Index::Unrestricted.new, Heucristic::Resolve::Scope::TOP).to_s
      .should eq("unknown (no annotation: no type restriction)")
  end

  it "locates an alias declaration without following it" do
    resolver = Heucristic::Resolve::Types.new(ws)
    located = resolver.locate(
      Heucristic::Syntax::Named.new(["Loop"], false), Heucristic::Resolve::Scope.of("Outer")
    )
    located.should eq("Outer::Loop")
  end

  it "finds a constant through an included module" do
    source = <<-CR
      module Shapes
        class Circle; end
      end

      class Canvas
        include Shapes
      end
      CR
    resolve(workspace(source), "Circle", "Canvas").should eq("Shapes::Circle")
  end

  it "finds a constant through the superclass" do
    source = <<-CR
      class Base
        class Config; end
      end

      class Child < Base
      end
      CR
    resolve(workspace(source), "Config", "Child").should eq("Base::Config")
  end

  it "prefers the enclosing namespace over an ancestor's constant" do
    source = <<-CR
      class Base
        class Config; end
      end

      module App
        class Config; end

        class Child < Base
        end
      end
      CR
    resolve(workspace(source), "Config", "App::Child").should eq("Base::Config")
  end

  it "collapses duplicate and nested union members" do
    resolve(ws, "Thing | Thing", "Outer").should eq("Outer::Thing")
    resolve(ws, "(Thing | Nil) | Nil", "Outer").should eq("Outer::Thing | Nil")
  end

  it "follows an alias used as a path prefix" do
    source = <<-CR
      module Config
        module Environment
          alias Any = Int32 | String
        end
      end

      module Commands
        alias Environment = Config::Environment

        class Login
        end
      end
      CR
    resolve(workspace(source), "Environment::Any", "Commands::Login").should eq("Int32 | String")
  end
end
