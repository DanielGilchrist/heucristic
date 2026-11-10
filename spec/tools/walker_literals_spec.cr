require "../spec_helper"
require "../../tools/score/features/walker"

private def literal_sites(tree : Crystal::ASTNode, source : String) : Array(Score::Features::Site)
  Score::Features::Walker.sites(tree, source).select(&.kind.literal?)
end

describe Score::Features::Walker do
  LITERAL_SNIPPETS.each do |snippet|
    it "emits one #{snippet.klass} site where the cursor finds it" do
      position = marked_source(snippet.owned)
      tree = Heucristic::Syntax.parse(position.source, "a.cr")
      raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

      sites = literal_sites(tree, position.source)
      sites.should contain(
        Score::Features::Site.new(
          Score::Features::Kind::Literal, position.line, position.column, snippet.klass
        )
      )
    end

    it "emits no #{snippet.klass} site as a type argument" do
      position = marked_source(snippet.owned)
      assignment = Heucristic::Syntax.parse(position.source, "a.cr")
      raise "unexpected syntax error" unless assignment.is_a?(Crystal::Assign)

      generic = Crystal::Generic.new(Crystal::Path.new("Foo"), [assignment.value])
      literal_sites(generic, position.source).should be_empty
    end
  end

  it "does not emit the source string of a regex as a literal of its own" do
    source = "x = /ab/\n"
    tree = Heucristic::Syntax.parse(source, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    literal_sites(tree, source).map(&.name).should eq(["RegexLiteral"])
  end
end
