require "../../spec_helper"

private def ancestors_of(source : String, name : String) : String
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  text = Heucristic::Document::Text.new(source)
  workspace.update(Heucristic::Index::Collector.collect("a.cr", text, tree))
  chain = Heucristic::Resolve::Types.new(workspace).ancestors(name)
  chain.is_a?(Heucristic::Resolve::Unknown) ? chain.to_s : chain.join(", ")
end

describe Heucristic::Resolve::Ancestors do
  it "lists includes most recent first, then the superclass chain" do
    source = <<-CR
      module Walk; end
      module Talk; end
      class Animal; end
      class Dog < Animal
        include Walk
        include Talk
      end
      CR
    ancestors_of(source, "Dog").should eq("Talk, Walk, Animal, Reference, Object")
  end

  it "follows includes of the ancestors and drops repeats" do
    source = <<-CR
      module Base; end
      module Mixed
        include Base
      end
      class Thing
        include Mixed
        include Base
      end
      CR
    ancestors_of(source, "Thing").should eq("Base, Mixed, Reference, Object")
  end

  it "gives a struct, an enum and a module their implicit parents" do
    source = <<-CR
      struct Point; end
      enum Colour; end
      module Helper; end
      CR
    ancestors_of(source, "Point").should eq("Struct, Value, Object")
    ancestors_of(source, "Colour").should eq("Enum, Value, Object")
    ancestors_of(source, "Helper").should eq("")
  end

  it "merges includes across reopenings and resolves parents from the type's own namespace" do
    source = <<-CR
      module Outer
        module Shared; end
        class Thing; end
        class Thing
          include Shared
        end
      end
      CR
    ancestors_of(source, "Outer::Thing").should eq("Outer::Shared, Reference, Object")
  end

  it "knows the compiler's builtin hierarchy" do
    ancestors_of("", "Int32").should eq("Int, Number, Value, Object")
    ancestors_of("", "String").should eq("Reference, Object")
  end

  it "refuses a chain with an unresolved parent instead of truncating it" do
    ancestors_of("class Thing < Missing; end", "Thing").should eq(
      "unknown (unresolved name: Missing)"
    )
    ancestors_of("class Thing\n  include Missing\nend", "Thing").should eq(
      "unknown (unresolved name: Missing)"
    )
  end

  it "refuses an inheritance cycle" do
    source = <<-CR
      module A
        include B
      end
      module B
        include A
      end
      CR
    ancestors_of(source, "A").should eq("unknown (cycle: A)")
  end

  it "reports an unknown type" do
    ancestors_of("", "Nope").should eq("unknown (unresolved name: Nope)")
  end
end

private def ancestors_in(files : Array({String, String}), name : String) : String
  workspace = Heucristic::Index::Workspace.new
  files.each do |path, source|
    tree = Heucristic::Syntax.parse(source, path)
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    text = Heucristic::Document::Text.new(source)
    workspace.update(Heucristic::Index::Collector.collect(path, text, tree))
  end
  chain = Heucristic::Resolve::Types.new(workspace).ancestors(name)
  chain.is_a?(Heucristic::Resolve::Unknown) ? chain.to_s : chain.join(", ")
end

describe Heucristic::Resolve::Ancestors, "file-private types" do
  it "follows the include of a single private type" do
    files = [{"a.cr", "module M; end\nprivate struct Foo\n  include M\nend\n"}]
    ancestors_in(files, "Foo").should eq("M, Struct, Value, Object")
  end

  it "does not leak a private type's include into a same-named private type in another file" do
    files = [
      {"a.cr", "module M; end\nprivate struct Foo\n  include M\nend\n"},
      {"b.cr", "private struct Foo\nend\n"},
    ]
    ancestors_in(files, "Foo").should start_with("unknown")
  end

  it "does not leak a private type's include into a public type of the same name" do
    files = [
      {"a.cr", "module M; end\nprivate struct Foo\n  include M\nend\n"},
      {"b.cr", "struct Foo\nend\n"},
    ]
    ancestors_in(files, "Foo").should start_with("unknown")
  end

  it "keeps a private type known when the semantic helper reopens it under a generated path" do
    files = [
      {"a.cr", "module M; end\nprivate struct Foo\n  include M\nend\n"},
      {"<macros:spec>", "struct Foo\n  def schema : Int32\n    1\n  end\nend\n"},
    ]
    ancestors_in(files, "Foo").should eq("M, Struct, Value, Object")
  end

  it "keeps a private type reopened in its own file known" do
    source = "module M; end\nprivate struct Foo\n  include M\nend\nprivate struct Foo\nend\n"
    files = [{"a.cr", source}]
    ancestors_in(files, "Foo").should eq("M, Struct, Value, Object")
  end

  it "keeps the first of a module included twice, as the compiler does (include X, Y, X is Y, X)" do
    source = "module X; end\nmodule Y; end\nclass C\n  include X\n  include Y\n  include X\nend\n"
    ancestors_of(source, "C").should eq("Y, X, Reference, Object")
  end

  it "orders a diamond by the include that came last (include A, B where B includes A is B, A)" do
    source = "module A; end\nmodule B\n  include A\nend\nclass C\n  include A\n  include B\nend\n"
    ancestors_of(source, "C").should eq("B, A, Reference, Object")
  end

  it "keeps a module included first ahead of one that includes it (include B, A is A, B)" do
    source = "module A; end\nmodule B\n  include A\nend\nclass C\n  include B\n  include A\nend\n"
    ancestors_of(source, "C").should eq("A, B, Reference, Object")
  end

  it "lists a module's own includes right after it, before earlier includes" do
    source = "module X; end\nmodule Y; end\nmodule Z\n  include X\nend\n" \
             "class C\n  include Y\n  include Z\nend\n"
    ancestors_of(source, "C").should eq("Z, X, Y, Reference, Object")
  end

  it "orders includes split across reopenings in one file by source position" do
    source = "module X; end\nmodule Y; end\nclass C\n  include X\nend\nclass C\n  include Y\nend\n"
    ancestors_of(source, "C").should eq("Y, X, Reference, Object")
  end

  it "does not guess the order of includes split across files when both define the same name" do
    files = [
      {"mods.cr", "module X\n  def f; end\nend\nmodule Y\n  def f; end\nend\n"},
      {"a.cr", "class C\n  include X\nend\n"},
      {"b.cr", "class C\n  include Y\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "does not guess when the names collide only in an included module's own include" do
    files = [
      {"mods.cr", "module W\n  def f; end\nend\nmodule X\n  include W\nend\n"},
      {"y.cr", "module Y\n  def f; end\nend\n"},
      {"a.cr", "class C\n  include X\nend\n"},
      {"b.cr", "class C\n  include Y\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "keeps includes split across files known when the modules share no names" do
    files = [
      {"mods.cr", "module X\n  def f; end\nend\nmodule Y\n  def g; end\nend\n"},
      {"a.cr", "class C\n  include X\nend\n"},
      {"b.cr", "class C\n  include Y\nend\n"},
    ]
    chain = ancestors_in(files, "C")
    chain.should_not start_with("unknown")
    chain.should contain("X")
    chain.should contain("Y")
  end

  it "accepts the same module included from several files" do
    files = [
      {"mods.cr", "module X; end\n"},
      {"a.cr", "class C\n  include X\nend\n"},
      {"b.cr", "class C\n  include X\nend\n"},
    ]
    ancestors_in(files, "C").should eq("X, Reference, Object")
  end

  it "takes the compiler's order from a generated reopening over the source order" do
    files = [
      {"mods.cr", "module X; end\nmodule Y; end\n"},
      {"a.cr", "class C\n  include X\nend\n"},
      {"b.cr", "class C\n  include Y\nend\n"},
      {"<macros>", "class C\n  include ::X\n  include ::Y\nend\n"},
    ]
    ancestors_in(files, "C").should eq("Y, X, Reference, Object")
  end

  it "does not guess when two compile targets disagree on the order" do
    files = [
      {"mods.cr", "module X\n  def f; end\nend\nmodule Y\n  def f; end\nend\n"},
      {"a.cr", "class C\n  include X\n  include Y\nend\n"},
      {"<macros>", "class C\n  include ::X\n  include ::Y\nend\n"},
      {"<macros:spec>", "class C\n  include ::Y\n  include ::X\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when both define a constant" do
    files = [
      {"ma.cr", "module A\n  FOO = 1\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  FOO = \"x\"\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when both declare a class variable" do
    files = [
      {"ma.cr", "module A\n  @@count : Int32 = 0\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  @@count : String = \"\"\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when both nest a type" do
    files = [
      {"ma.cr", "module A\n  class Foo; end\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  class Foo; end\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when both define an alias" do
    files = [
      {"ma.cr", "module A\n  alias Foo = Int32\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  alias Foo = String\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when one has an included hook" do
    files = [
      {"ma.cr", "module A\n  macro included\n  end\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when one has a method_missing" do
    files = [
      {"ma.cr", "module A\n  def method_missing(name)\n  end\n  def fa; end\nend\n"},
      {"mb.cr", "module B\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when one calls a macro in its body" do
    files = [
      {"ma.cr", "module A\n  def fa; end\n  declare_things :x\nend\n"},
      {"mb.cr", "module B\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end

  it "leaves split includes unknown when one has a macro for in its body" do
    files = [
      {"ma.cr", "module A\n  def fa; end\n  {% for n in %w(x) %}\n  {{n.id}}\n  {% end %}\nend\n"},
      {"mb.cr", "module B\n  def fb; end\nend\n"},
      {"a.cr", "class C\n  include A\nend\n"},
      {"b.cr", "class C\n  include B\nend\n"},
    ]
    ancestors_in(files, "C").should start_with("unknown")
  end
end
