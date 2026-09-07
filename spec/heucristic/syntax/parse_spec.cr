require "../../spec_helper"

describe Heucristic::Syntax do
  it "parses valid source" do
    Heucristic::Syntax.parse("def foo; end", "a.cr").should be_a(Crystal::ASTNode)
  end

  it "reports the location of a syntax error as a value" do
    broken = Heucristic::Syntax.parse("def foo(\nend", "a.cr")
    broken.should be_a(Heucristic::Syntax::Broken)
    broken.as?(Heucristic::Syntax::Broken).try(&.at.line).should eq(2)
  end
end
