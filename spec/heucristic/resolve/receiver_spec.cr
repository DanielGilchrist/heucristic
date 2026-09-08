require "../../spec_helper"

private SOURCE = <<-CR
  module Shapes
    class Circle
      def initialize(@radius : Float64) : Nil
      end
    end
  end

  class Canvas
    include Shapes

    @title : String

    def initialize(@width : Int32, height) : Nil
      @title = "c"
    end

    def draw(shape : Circle, label, count : Int32? = nil) : Nil
      scale : Float64 = 1.0
      shape
    end

    def self.build : Canvas
      new(1, 2)
    end
  end

  def top
  end
  CR

private def receiver_of(marker : String) : String
  tree = Heucristic::Syntax.parse(SOURCE, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  text = Heucristic::Document::Text.new(SOURCE)
  workspace.update(Heucristic::Index::Collector.collect("a.cr", text, tree))
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  shims = Heucristic::Index::Shims.new
  receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)

  line = SOURCE.lines.index!(&.includes?(marker)) + 1
  column = SOURCE.lines[line - 1].index!(marker) + 1
  target = Heucristic::Syntax::Cursor.find(tree, Heucristic::Document::Point.new(line, column))
  case target
  in Heucristic::Syntax::OnCall        then receiver.of_call(target.node, target.context).to_s
  in Heucristic::Syntax::OnVar         then receiver.variable(target.name, target.context).to_s
  in Heucristic::Syntax::OnInstanceVar then receiver.instance_var(target.name, target.context).to_s
  in Heucristic::Syntax::OnDef, Heucristic::Syntax::OnPath, Nil
    raise "cursor did not land on a call or variable at #{marker.inspect}"
  end
end

describe Heucristic::Resolve::Receiver do
  it "types a parameter from its restriction, resolved through the owner's ancestors" do
    receiver_at(SOURCE, 19, 5).should eq("Shapes::Circle")
  end

  it "types a local from its declaration" do
    receiver_of("scale").should eq("Float64")
  end

  it "resolves a nilable parameter to a union" do
    receiver_of("count").should eq("Int32 | Nil")
  end

  it "says so when a parameter has no restriction" do
    receiver_of("label").should eq(
      "unknown (no annotation: parameter label has no type restriction)"
    )
  end

  it "types a declared instance variable" do
    receiver_of("@title = ").should eq("String")
  end

  it "types an instance variable declared through a parameter" do
    receiver_of("@width").should eq("Int32")
  end

  it "types the implicit receiver of a call inside a class method as the metaclass" do
    receiver_of("new(1, 2)").should eq("Canvas.class")
  end
end

private def receiver_at(source : String, line : Int32, column : Int32) : String
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
  )
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  shims = Heucristic::Index::Shims.new
  receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
  target = Heucristic::Syntax::Cursor.find(tree, Heucristic::Document::Point.new(line, column))
  case target
  in Heucristic::Syntax::OnCall        then receiver.of_call(target.node, target.context).to_s
  in Heucristic::Syntax::OnVar         then receiver.variable(target.name, target.context).to_s
  in Heucristic::Syntax::OnInstanceVar then receiver.instance_var(target.name, target.context).to_s
  in Heucristic::Syntax::OnDef, Heucristic::Syntax::OnPath, Nil
    raise "cursor did not land on a call or variable at #{line}:#{column}"
  end
end

describe Heucristic::Resolve::Receiver, "expressions" do
  source = <<-CR
    class Thing
      def go(x : Int32, y) : Nil
        Thing.new.go(1, 2)
        Thing.go(1, 2)
        "s".size
        1.5.abs
        y.size
        (x.as(String)).size
      end
    end
    CR

  it "types Const.new as an instance and a bare constant as the metaclass" do
    receiver_at(source, 3, 15).should eq("Thing")
    receiver_at(source, 4, 11).should eq("Thing.class")
  end

  it "types literals" do
    receiver_at(source, 5, 9).should eq("String")
    receiver_at(source, 6, 9).should eq("Float64")
  end

  it "does not guess the result of a call on an unannotated variable" do
    receiver_at(source, 7, 7).should eq(
      "unknown (no annotation: parameter y has no type restriction)"
    )
  end

  it "trusts a cast" do
    receiver_at(source, 8, 20).should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "assignments" do
  source = <<-CR
    class Store
    end

    class Session
      def initialize : Nil
        @store = Store.new
        @mixed = Store.new
      end

      def reset : Nil
        @mixed = nil
        @store = build
      end

      def run(input : String) : Nil
        local = Store.new
        local.size
        copy = input
        copy.size
        either = Store.new
        either = 1
        either.size
        opaque = build
        opaque.size
        @store.size
        @mixed.size
      end
    end
    CR

  it "types a local from an evident assignment" do
    receiver_at(source, 17, 11).should eq("Store")
  end

  it "types a local assigned from an annotated parameter" do
    receiver_at(source, 19, 10).should eq("String")
  end

  it "unions the evident assignments of a local" do
    receiver_at(source, 22, 12).should eq("Store | Int32")
  end

  it "refuses a local assigned from a call it cannot find" do
    receiver_at(source, 24, 12).should eq("unknown (unresolved name: no `build` on Session)")
  end

  it "types an ivar from its evident assignments and ignores call results, like the compiler" do
    receiver_at(source, 25, 12).should eq("Store")
    receiver_at(source, 26, 12).should eq("Store | Nil")
  end
end

private def receiver_of_size(source : String, line_text : String) : String
  line = source.lines.index!(&.includes?(line_text)) + 1
  column = source.lines[line - 1].index!(line_text) + line_text.rindex!("size") + 1
  receiver_at(source, line, column)
end

describe Heucristic::Resolve::Receiver, "call results" do
  source = <<-CR
    module Enumerable(T)
      def first : T
      end

      def flat_map(& : T -> _)
      end
    end

    class Array(T)
      include Enumerable(T)

      def uniq! : self
      end
    end

    class Channel(T)
      def receive : T
      end
    end

    class Builder
      def build : Array(String)
      end

      def run(names : Array(String), results : Channel(Array(Int32)?)) : Nil
        names.first.size
        names.uniq!.size
        results.receive.size
        build.size
        names.flat_map { |name| name }.size
        paths = names.flat_map { |name| name }.uniq!
        paths.size
      end
    end
    CR

  it "binds a type variable to the receiver's argument through an include" do
    receiver_of_size(source, "names.first.size").should eq("String")
  end

  it "resolves self to the receiver with its arguments" do
    receiver_of_size(source, "names.uniq!.size").should eq("Array(String)")
  end

  it "binds a type variable on the receiver's own type" do
    receiver_of_size(source, "results.receive.size").should eq("Array(Int32) | Nil")
  end

  it "types the result of an implicit self call from its return restriction" do
    receiver_of_size(source, "build.size").should eq("Array(String)")
  end

  it "names the def that lacks a return type" do
    receiver_of_size(source, "names.flat_map { |name| name }.size").should eq(
      "unknown (no annotation: Enumerable#flat_map has no return type restriction)"
    )
    receiver_of_size(source, "paths.size").should eq(
      "unknown (no annotation: Enumerable#flat_map has no return type restriction)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "argument bindings" do
  source = <<-CR
    class Array(T)
      def +(other : Array(U)) : Array(T | U) forall U
      end

      def zip(other : Array(U)) : Array(Tuple(T, U)) forall U
      end
    end

    class Box
      def pair(a : Array(String), b : Array(Int32), c : Int32?) : Nil
        (a + b).size
        a.zip(b).size
        wrap(c).size
      end

      def wrap(value : U?) : Array(U) forall U
      end
    end
    CR

  it "binds a def's free variable from the matching argument" do
    receiver_of_size(source, "(a + b).size").should eq("Array(String | Int32)")
    receiver_of_size(source, "a.zip(b).size").should eq("Array(Tuple(String, Int32))")
  end

  it "binds through a nilable restriction" do
    receiver_of_size(source, "wrap(c).size").should eq("Array(Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "overloads" do
  source = <<-CR
    module Math
      extend self

      def min(value1 : Float32, value2 : Float32) : Float32
      end

      def min(value1 : Float64, value2 : Float64) : Float64
      end

      def min(value1, value2)
      end
    end

    class Calc
      def run(a : Int32, b : Float64, c : Float64, d) : Nil
        Math.min(a, a).abs
        Math.min(b, c).abs
        Math.min(d, d).abs
      end
    end
    CR

  it "picks the overload whose restrictions admit the argument types" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(b, c).size").should eq("Float64")
  end

  it "refuses to guess when the argument types rule out every typed overload" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(a, a).size").should eq(
      "unknown (no annotation: Math#min has no return type restriction)"
    )
  end

  it "keeps every overload for an unknown argument and reports the ambiguity" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(d, d).size").should eq(
      "unknown (ambiguous: 3 overloads of `min` do not agree on a type)"
    )
  end

  it "does not pick the typed overload over an untyped one when the argument is unknown" do
    source = <<-CR
      module Math
        extend self

        def max(value1 : Float64, value2 : Float64) : Float64
        end

        def max(value1, value2)
        end
      end

      def go(d) : Nil
        Math.max(d, d).size
      end
      CR
    receiver_of_size(source, "Math.max(d, d).size").should eq(
      "unknown (ambiguous: 2 overloads of `max` do not agree on a type)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "block results" do
  source = <<-CR
    class String
      def size : Int32
      end
    end

    module Enumerable(T)
      def flat_map(& : T -> Array(U) | Iterator(U) | U) : Array(U) forall U
      end

      def sum(& : T -> U) : U forall U
      end

      def each(& : T ->) : Nil
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Dir
      def self.glob(pattern : String) : Array(String)
      end
    end

    class Walker
      def run(roots : Array(String)) : Nil
        roots.flat_map { |root| Dir.glob(root) }.size
        roots.flat_map { |root| root }.size
        roots.sum { |root| root.size }.size
        roots.flat_map { |root| unknown_call(root) }.size
      end
    end
    CR

  it "binds a free variable from the block result through the shaped union member" do
    receiver_of_size(source, "roots.flat_map { |root| Dir.glob(root) }.size").should eq(
      "Array(String)"
    )
  end

  it "binds a free variable from a bare block result" do
    receiver_of_size(source, "roots.flat_map { |root| root }.size").should eq("Array(String)")
    receiver_of_size(source, "roots.sum { |root| root.size }.size").should eq("Int32")
  end

  it "leaves the variable free when the block result is unknown" do
    receiver_of_size(source, "roots.flat_map { |root| unknown_call(root) }.size").should eq(
      "Array(unknown (free variable: U))"
    )
  end
end

describe Heucristic::Resolve::Receiver, "block parameters" do
  source = <<-CR
    module Enumerable(T)
      def each_with_index(offset = 0, & : T, Int32 ->) : Nil
      end

      def each(& : T ->) : Nil
      end

      def sort_by(&)
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Walker
      def run(names : Array(String)) : Nil
        names.each_with_index do |name, index|
          name.size
          index.size
          names.each { |inner| inner.size }
        end
        names.sort_by { |name| name.size }
      end
    end
    CR

  it "types block parameters from the yielding def's block restriction" do
    receiver_of_size(source, "name.size").should eq("String")
    receiver_of_size(source, "index.size").should eq("Int32")
  end

  it "resolves a nested block against its own call" do
    receiver_of_size(source, "inner.size").should eq("String")
  end

  it "says so when the def does not state what it yields" do
    receiver_of_size(source, "names.sort_by { |name| name.size }").should eq(
      "unknown (no annotation: Enumerable#sort_by does not state what it yields)"
    )
  end
end
