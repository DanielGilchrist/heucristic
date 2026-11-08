require "../../spec_helper"

private def special_of(source : String) : Heucristic::Resolve::Special?
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  text = Heucristic::Document::Text.new(source)
  index = Heucristic::Index::Collector.collect("a.cr", text, tree, SPEC_CRYSTAL)
  Heucristic::Resolve::Special.for(index.defs.first)
end

describe Heucristic::Resolve::Special do
  it "names an instance def by its owner and name" do
    special_of("class Object\n  def class\n  end\nend").try(&.object_class?).should be_true
  end

  it "separates a metaclass def from an instance def of the same name" do
    special_of("class Enum\n  def self.each\n  end\nend").try(&.enum_each?).should be_true
    special_of("class Enum\n  def each\n  end\nend").should be_nil
  end

  it "names a top-level loop and nothing else called loop" do
    special_of("def loop\nend").try(&.loop?).should be_true
    special_of("class Foo\n  def loop\n  end\nend").should be_nil
  end

  it "keeps zip and zip? apart" do
    nilable = special_of("module Enumerable\n  def zip?\n  end\nend")
    plain = special_of("module Enumerable\n  def zip\n  end\nend")
    nilable.try(&.enumerable_zip_or_nil?).should be_true
    plain.try(&.enumerable_zip?).should be_true
  end
end
