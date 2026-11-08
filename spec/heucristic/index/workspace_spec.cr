require "../../spec_helper"

private def file(path : String, source : String) : Heucristic::Index::File
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Index::Collector.collect(
    path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
  )
end

describe Heucristic::Index::Workspace do
  it "merges reopenings from several files and forgets a removed file" do
    workspace = Heucristic::Index::Workspace.new
    workspace.update(file("a.cr", "class Foo\n  include Bar\n  @x : Int32\nend\n"))
    workspace.update(file("b.cr", "class Foo\n  def go; end\nend\nalias Names = Array(String)\n"))

    workspace.namespaces("Foo").map(&.path).should eq(["a.cr", "b.cr"])
    workspace.mixins_of("Foo").size.should eq(1)
    workspace.instance_vars_of("Foo").map(&.name).should eq(["@x"])
    workspace.named("go").size.should eq(1)
    workspace.aliases("Names").size.should eq(1)

    workspace.remove("a.cr")
    workspace.namespaces("Foo").map(&.path).should eq(["b.cr"])
    workspace.mixins_of("Foo").should be_empty
    workspace.instance_vars_of("Foo").should be_empty
  end

  it "replaces a file's entries on update" do
    workspace = Heucristic::Index::Workspace.new
    workspace.update(file("a.cr", "class Foo; end\n"))
    workspace.update(file("a.cr", "class Bar; end\n"))

    workspace.namespaces("Foo").should be_empty
    workspace.namespaces("Bar").size.should eq(1)
  end
end
