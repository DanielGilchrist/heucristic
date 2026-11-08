require "../../spec_helper"

private PRELUDE = <<-CR
  class Object
  end

  class Reference < Object
  end

  struct Int32
  end

  CR

private def instance_var_findings(body : String) : Array(String)
  source = PRELUDE + body
  path = "/project/a.cr"
  text = Heucristic::Document::Text.new(source)
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(Heucristic::Index::Collector.collect(path, text, tree, SPEC_CRYSTAL))
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
  sites = Heucristic::Index::Sites.of(path, text, tree, SPEC_CRYSTAL)
  findings = Array(Heucristic::Check::Finding).new
  Heucristic::Check::InstanceVars.new(environment).run(sites, findings)
  findings.map(&.message)
end

describe Heucristic::Check::InstanceVars do
  it "checks an assignment against a file-private declared type" do
    source = <<-CR
      private class Wrapper
      end

      class Holder
        @wrapper : Wrapper

        def initialize
          @wrapper = Wrapper.new
        end

        def reset : Nil
          @wrapper = 1
        end
      end
      CR
    instance_var_findings(source).should eq([
      "instance variable '@wrapper' of Holder must be Wrapper, not Int32",
    ])
  end
end
