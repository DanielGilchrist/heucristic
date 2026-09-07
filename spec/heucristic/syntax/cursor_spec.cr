require "../../spec_helper"

private def target_at(source : String, line : Int32, column : Int32) : Heucristic::Syntax::Target?
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Syntax::Cursor.find(tree, Heucristic::Document::Point.new(line, column))
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
end
