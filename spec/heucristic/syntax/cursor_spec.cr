require "../../spec_helper"

private def target_at(source : String, line : Int32, column : Int32) : Heucristic::Syntax::Target?
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Syntax::Cursor.find(
    tree, Heucristic::Document::Point.new(line, column), "a.cr"
  )
end

describe Heucristic::Syntax::Cursor do
  source = <<-'CR'
    def greet(name : String) : String
      "hi #{name}"
    end

    greet("x")
    CR

  it "finds a def by its name" do
    target = target_at(source, 1, 6)
    target.should be_a(Heucristic::Syntax::OnDef)
  end

  it "finds a call inside a macro if whose flag it cannot decide" do
    flagged = <<-CR
      def run
        {% if flag?(:custom) %}
          greet("a")
        {% else %}
          shout("b")
        {% end %}
      end
      CR
    taken = target_at(flagged, 3, 6)
    taken.should be_a(Heucristic::Syntax::OnCall)
    taken.as(Heucristic::Syntax::OnCall).node.name.should eq("greet")
    skipped = target_at(flagged, 5, 6)
    skipped.should be_a(Heucristic::Syntax::OnCall)
    skipped.as(Heucristic::Syntax::OnCall).node.name.should eq("shout")
  end

  it "finds a call by its name" do
    target = target_at(source, 5, 3)
    target.should be_a(Heucristic::Syntax::OnCall)
  end

  it "does not match the receiver or arguments" do
    target_at(source, 5, 8).should be_nil
  end

  it "does not match the keyword" do
    target_at(source, 1, 2).should be_nil
  end

  nested = <<-CR
    module Outer
      class Inner
        def build(other : Other::Thing) : Inner
          Inner.new
        end
      end
    end
    CR

  it "finds a constant path and records the enclosing namespaces" do
    target = target_at(nested, 4, 7)
    target.should be_a(Heucristic::Syntax::OnPath)
    enclosing = target.as?(Heucristic::Syntax::OnPath).try(&.context.enclosing)
    enclosing.should eq(["Outer", "Outer::Inner"])
  end

  it "finds a path inside a type restriction" do
    target = target_at(nested, 3, 23)
    target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Other::Thing")
  end

  it "records which segment of a path the point is on" do
    source = "x = Outer::Inner::Thing\n"
    first = target_at(source, 1, 6).as?(Heucristic::Syntax::OnPath)
    middle = target_at(source, 1, 13).as?(Heucristic::Syntax::OnPath)
    last = target_at(source, 1, 20).as?(Heucristic::Syntax::OnPath)
    {first.try(&.segment), middle.try(&.segment), last.try(&.segment)}.should eq({0, 1, 2})
  end
end
