require "../../spec_helper"

private PRELUDE = <<-CR
  class Object
  end

  class Reference < Object
  end

  CR

private def generic_findings(body : String) : Array(String)
  source = PRELUDE + body
  path = "/project/a.cr"
  text = Heucristic::Document::Text.new(source)
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(Heucristic::Index::Collector.collect(path, text, tree))
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  receiver = Heucristic::Resolve::Receiver.new(
    workspace, Heucristic::Index::Shims.new, types, methods
  )
  settled = Heucristic::Check::Settled.new(
    workspace, types, methods.descendants, true, Set(String).new, Set{path}, "/project",
    Array(String).new
  )
  environment = Heucristic::Check::Environment.new(
    workspace, types, methods, receiver, settled, "/project"
  )
  sites = Heucristic::Index::Sites.of(path, text, tree)
  findings = Array(Heucristic::Check::Finding).new
  Heucristic::Check::Generics.new(environment).run(sites, findings)
  findings.map(&.message)
end

describe Heucristic::Check::Generics do
  it "checks the type variables of a file-private generic type" do
    source = <<-CR
      private class Box(T)
      end

      def wrong(box : Box(Int32, String)) : Nil
      end
      CR
    generic_findings(source).should eq([
      "wrong number of type vars for Box(T) (given 2, expected 1)",
    ])
  end

  it "stays quiet for a valid use of a file-private generic type" do
    source = <<-CR
      private class Box(T)
      end

      def right(box : Box(Int32)) : Nil
      end
      CR
    generic_findings(source).should be_empty
  end

  it "reports a file-private type used with type variables when it has none" do
    source = <<-CR
      private class Plain
      end

      def wrong(plain : Plain(Int32)) : Nil
      end
      CR
    generic_findings(source).should eq(["Plain is not a generic type, it's a class"])
  end
end
