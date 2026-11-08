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
    result_of(receiver, bag, "compact_map", 0, true).should eq(
      "Array(unknown (free variable: " \
      "U is not fixed by the arguments or block of Enumerable#compact_map))"
    )
  end

  it "lets a shim restrict a parameter the stdlib leaves unrestricted" do
    shims = Heucristic::Index::Shims.new
    shim_source = "module Math\n  def min(a : T, b : U) : T | U forall T, U\n  end\nend\n"
    shims.replace_all([collect("shims/math.cr", shim_source)])
    stdlib_source = <<-CR
      module Math
        def min(a, b)
        end

        def min(a : Float64, b : Float64) : Float64
        end
      end
      CR
    stdlib = collect("math.cr", stdlib_source)

    shims.find(stdlib.defs[0]).try(&.entry.return_type.to_s).should eq("T | U")
    shims.find(stdlib.defs[1]).should be_nil
  end
end

describe Heucristic::Resolve::Receiver, "typeof a parameter in a shim" do
  it "types typeof(parameter) as the argument, or the default when it is left out" do
    stdlib_source = <<-CR
      module Iterator(T)
        def with_index(offset : Int = 0)
        end
      end

      class Counter
        include Iterator(String)
      end
      CR
    shim_source = <<-CR
      module Iterator(T)
        def with_index(offset : Int = 0) : Iterator(Tuple(T, typeof(offset)))
        end
      end
      CR
    workspace = Heucristic::Index::Workspace.new
    workspace.update(collect("iterator.cr", stdlib_source))
    shims = Heucristic::Index::Shims.new
    shims.replace_all([collect("shims/iterator.cr", shim_source)])
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    none = Array(Heucristic::Resolve::Resolution).new
    counter = Heucristic::Resolve::TypeRef.new("Counter", none)
    int64 = Heucristic::Resolve::TypeRef.new("Int64", none)

    arguments = [int64] of Heucristic::Resolve::Resolution
    explicit = Heucristic::Resolve::Methods::Call.new("with_index", 1, false, arguments)
    receiver.result_of(counter, explicit).to_s.should eq("Iterator(Tuple(String, Int64))")
    defaulted = Heucristic::Resolve::Methods::Call.new("with_index", 0, false)
    receiver.result_of(counter, defaulted).to_s.should eq("Iterator(Tuple(String, Int32))")
  end
end

describe Heucristic::Resolve::Methods, "generated number shims" do
  it "leave defs the stdlib declares in source on Int to the stdlib" do
    workspace = Heucristic::Index::Workspace.new
    workspace.update(collect("int.cr", "struct Int\n  def <<(count : Int)\n  end\nend\n"))
    generated = File.read("shims/generated/numbers.cr")
    workspace.update(collect("shims/generated/numbers.cr", generated))
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    int32 = Heucristic::Resolve::TypeRef.new("Int32", Array(Heucristic::Resolve::Resolution).new)

    found = methods.lookup(int32, Heucristic::Resolve::Methods::Call.new("<<", 1, false))

    found.map(&.path).should eq(["int.cr"])
  end
end
