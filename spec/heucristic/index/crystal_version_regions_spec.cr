require "../../spec_helper"

private SOURCE = <<-CR
  class Gate
    {% if compare_versions(Crystal::VERSION, "1.22.0") >= 0 %}
      def modern : Nil
      end
    {% else %}
      def legacy : Nil
      end
    {% end %}

    def always : Nil
    end
  end
  CR

private def defs_under(version : Heucristic::CrystalVersion::Detected) : Array(String)
  tree = Heucristic::Syntax.parse(SOURCE, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  file = Heucristic::Index::Collector.collect(
    "a.cr", Heucristic::Document::Text.new(SOURCE), tree, version
  )
  file.defs.map(&.qualified).sort!
end

describe "Crystal version regions" do
  it "takes the branch the injected version selects" do
    defs_under(Heucristic::CrystalVersion.parse("1.22.2")).should eq(["Gate#always", "Gate#modern"])
    defs_under(Heucristic::CrystalVersion.parse("1.21.0")).should eq(["Gate#always", "Gate#legacy"])
  end

  it "contributes nothing when the version is unknown" do
    unknown = Heucristic::CrystalVersion::Unknown.new("crystal not found")
    defs_under(unknown).should eq(["Gate#always"])
  end

  it "indexes the same file under the same version identically" do
    version = Heucristic::CrystalVersion.parse("1.21.0")
    defs_under(version).should eq(defs_under(version))
  end

  it "reports unparseable versions as unknown" do
    Heucristic::CrystalVersion.parse("nightly").should be_a(Heucristic::CrystalVersion::Unknown)
  end

  it "answers a cursor inside the branch the version drops from the other branch" do
    tree = Heucristic::Syntax.parse(SOURCE, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    version = Heucristic::CrystalVersion.parse("1.21.0")
    point = Heucristic::Document::Point.new(3, 11)
    target = Heucristic::Syntax::Cursor.find(tree, point, "a.cr", version, SOURCE)
    target.should be_a(Heucristic::Syntax::OnDef)
  end
end

describe Heucristic::Index::ShimCoverage do
  it "warns when the minor version differs from the one the shims were checked against" do
    checked = Heucristic::CrystalVersion.parse(Heucristic::Index::ShimCoverage::CHECKED)
    Heucristic::Index::ShimCoverage.drift(checked).should be_nil
    drifted = Heucristic::CrystalVersion.parse("1.99.0")
    Heucristic::Index::ShimCoverage.drift(drifted).should_not be_nil
  end

  it "stays quiet for an unknown version" do
    unknown = Heucristic::CrystalVersion::Unknown.new("crystal not found")
    Heucristic::Index::ShimCoverage.drift(unknown).should be_nil
  end
end
