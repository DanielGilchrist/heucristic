require "../../spec_helper"

private def unimplemented(source : String) : Array(String)
  path = "/project/a.cr"
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
  )
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  settled = Heucristic::Check::Settled.new(
    workspace, types, methods.descendants, true, Set(String).new, Set{path}, "/project",
    Array(String).new
  )
  findings = Array(Heucristic::Check::Finding).new
  receiver = Heucristic::Resolve::Receiver.new(
    workspace, Heucristic::Index::Shims.new, types, methods
  )
  environment = Heucristic::Check::Environment.new(
    workspace, types, methods, receiver, settled, "/project"
  )
  text = Heucristic::Document::Text.new(source)
  sites = Heucristic::Index::Sites.of(path, text, tree)
  Heucristic::Check::Abstracts.new(environment).run(sites, findings)
  findings.map(&.message)
end

describe Heucristic::Check::Abstracts do
  it "accepts a def declared beside the abstract def in the abstract class itself" do
    source = <<-CR
      class Object
      end

      class Reference < Object
      end

      abstract class Display
        abstract def width : Int32
        getter width : Int32

        def initialize(@width : Int32)
        end
      end

      class Canvas < Display
      end
      CR
    unimplemented(source).should be_empty
  end

  it "reports an abstract def nothing implements" do
    source = <<-CR
      class Object
      end

      class Reference < Object
      end

      abstract class Display
        abstract def width : Int32
      end

      class Canvas < Display
      end
      CR
    unimplemented(source).should eq([
      "abstract `def Display#width()` must be implemented by Canvas",
    ])
  end
end
