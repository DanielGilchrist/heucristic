require "../../spec_helper"

private def collect(path : String, source : String) : Heucristic::Index::File
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Index::Collector.collect(path, Heucristic::Document::Text.new(source), tree)
end

private STDLIB = <<-CR
  module Enumerable(T)
    def compact_map(& : T -> _)
    end

    def first : T
    end

    def join(separator = "", & : T ->)
    end
  end
  CR

private SHIMS = <<-CR
  module Enumerable(T)
    def compact_map(& : T -> U?) : Array(U) forall U
    end

    def first : Int32
    end

    def join(separator = "", & : T ->) : String
    end

    def vanished : Nil
    end
  end
  CR

describe Heucristic::Index::Shims do
  it "matches a shim to a def by owner, name and parameters, ignoring the block restriction" do
    shims = Heucristic::Index::Shims.new
    shims.replace_all([collect("shims/enumerable.cr", SHIMS)])
    stdlib = collect("enumerable.cr", STDLIB)

    compact_map = stdlib.defs.find!(&.name.==("compact_map"))
    shims.find(compact_map).try(&.entry.return_type.to_s).should eq("Array(U)")
    join = stdlib.defs.find!(&.name.==("join"))
    shims.find(join).try(&.entry.return_type.to_s).should eq("String")
  end

  it "keys on the parameter list so a changed signature no longer matches" do
    shims = Heucristic::Index::Shims.new
    shims.replace_all([collect("shims/enumerable.cr", SHIMS)])
    source = "module Enumerable(T)\n  def join(sep, io : IO, &)\n  end\nend\n"
    changed = collect("enumerable.cr", source)
    shims.find(changed.defs[0]).should be_nil
  end
end

private def result_of(
  receiver : Heucristic::Resolve::Receiver,
  target : Heucristic::Resolve::TypeRef,
  name : String,
  arity : Int32,
  block : Bool,
) : String
  receiver.result_of(target, Heucristic::Resolve::Methods::Call.new(name, arity, block)).to_s
end

describe Heucristic::Resolve::Receiver, "with shims" do
  it "uses the shim only when the stdlib def has no return type" do
    workspace = Heucristic::Index::Workspace.new
    workspace.update(collect("enumerable.cr", STDLIB))
    workspace.update(collect("a.cr", "class Bag\n  include Enumerable(String)\nend\n"))
    shims = Heucristic::Index::Shims.new
    shims.replace_all([collect("shims/enumerable.cr", SHIMS)])
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    bag = Heucristic::Resolve::TypeRef.new("Bag", Array(Heucristic::Resolve::Resolution).new)

    result_of(receiver, bag, "join", 1, true).should eq("String")
    result_of(receiver, bag, "first", 0, false).should eq("String")
    result_of(receiver, bag, "compact_map", 0, true).should eq("Array(unknown (free variable: U))")
  end
end
