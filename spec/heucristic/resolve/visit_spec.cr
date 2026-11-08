require "../../spec_helper"

private def visit_of(source : String, path : String) : Heucristic::Resolve::DefVisit
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  text = Heucristic::Document::Text.new(source)
  entry = Heucristic::Index::Collector.collect(path, text, tree, SPEC_CRYSTAL).defs.first
  Heucristic::Resolve::DefVisit.of(entry)
end

describe Heucristic::Resolve::DefVisit do
  it "tells a def of a file-private type from the same def of a public type of that name" do
    private_visit = visit_of("private class Foo\n  def bar\n  end\nend\n", "a.cr")
    public_visit = visit_of("class Foo\n  def bar\n  end\nend\n", "b.cr")
    private_visit.should_not eq(public_visit)
  end

  it "names the cycle after the owner and def" do
    visit_of("class Foo\n  def self.bar\n  end\nend\n", "a.cr").cycle.to_s.should eq(
      "unknown (cycle: Foo.bar)"
    )
  end
end
