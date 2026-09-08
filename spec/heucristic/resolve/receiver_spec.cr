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
  receiver = Heucristic::Resolve::Receiver.new(workspace, types)

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
  receiver = Heucristic::Resolve::Receiver.new(workspace, Heucristic::Resolve::Types.new(workspace))
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

  it "refuses a local assigned from a call result" do
    receiver_at(source, 24, 12).should eq(
      "unknown (inference needed: the result of `build` needs type inference)"
    )
  end

  it "types an ivar from its evident assignments and ignores call results, like the compiler" do
    receiver_at(source, 25, 12).should eq("Store")
    receiver_at(source, 26, 12).should eq("Store | Nil")
  end
end
