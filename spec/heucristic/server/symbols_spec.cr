require "../../spec_helper"

private def symbols_over(files : Array({String, String})) : Heucristic::Server::Symbols
  workspace = Heucristic::Index::Workspace.new
  files.each do |path, source|
    tree = Heucristic::Syntax.parse(source, path)
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    text = Heucristic::Document::Text.new(source)
    workspace.update(Heucristic::Index::Collector.collect(path, text, tree, SPEC_CRYSTAL))
  end
  Heucristic::Server::Symbols.new(workspace)
end

describe Heucristic::Server::Symbols do
  it "places a reopened type at the reopening that declares the most of its defs" do
    symbols = symbols_over([
      {"/project/src/thin.cr", "class Widget\nend\n"},
      {"/project/src/thick.cr", "class Widget\n  def a; end\n  def b; end\nend\n"},
    ])

    found = symbols.matching("Widget", "/project").find { |symbol| symbol.name == "Widget" }
    found.try(&.location.uri.to_s).should eq("file:///project/src/thick.cr")
  end
end
