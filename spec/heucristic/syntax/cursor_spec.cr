require "../../spec_helper"

private def target_at(source : String, line : Int32, column : Int32) : Heucristic::Syntax::Target?
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Syntax::Cursor.find(
    tree, Heucristic::Document::Point.new(line, column), "a.cr", SPEC_CRYSTAL
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

  it "keeps parameters as variables inside an expanded macro region" do
    region = <<-CR
      class Usage
        def initialize(usage)
          {% if true %}
            @max = usage.ru_maxrss
          {% end %}
        end
      end
      CR
    tree = Heucristic::Syntax.parse(region, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    uses = Heucristic::Syntax::Uses.in(tree, "a.cr", SPEC_CRYSTAL)
    receivers = uses.calls.select(&.call.name.==("ru_maxrss")).map(&.call.obj.class.name)
    receivers.should eq(["Crystal::Var"])
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
    enclosing = target.as?(Heucristic::Syntax::OnPath).try(&.context.enclosing.map(&.name))
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

  describe "index calls" do
    {"a[idx]", "a[idx]?", "a[idx] = 1"}.each do |expression|
      it "finds the argument inside #{expression}, not the index call" do
        source = "def f(a, idx)\n  #{expression}\nend\n"
        target = target_at(source, 2, 5).as?(Heucristic::Syntax::OnVar)
        target.try(&.name).should eq("idx")
      end

      it "finds the index call on the opening bracket of #{expression}" do
        source = "def f(a, idx)\n  #{expression}\nend\n"
        target = target_at(source, 2, 4).as?(Heucristic::Syntax::OnCall)
        target.try(&.node.name.starts_with?("[]")).should be_true
      end
    end

    it "finds the index call on the closing bracket" do
      source = "def f(a, idx)\n  a[idx]\nend\n"
      target = target_at(source, 2, 8).as?(Heucristic::Syntax::OnCall)
      target.try(&.node.name).should eq("[]")
    end

    it "finds the innermost argument of a nested index" do
      source = "def f(a, b, c)\n  a[b[c]]\nend\n"
      target = target_at(source, 2, 7).as?(Heucristic::Syntax::OnVar)
      target.try(&.name).should eq("c")
    end
  end
end
