require "../../spec_helper"

private def index(source : String) : Heucristic::Index::File
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Index::Collector.collect("a.cr", Heucristic::Document::Text.new(source), tree)
end

describe Heucristic::Index::Collector do
  it "records defs with their owner, receiver and signature" do
    file = index(<<-CR)
      module Outer
        class Inner
          def self.build(count : Int32) : Inner
          end

          private def run(*args, key : String = "k", &block : Int32 -> Nil) : Nil
          end
        end
      end

      def top
      end
      CR

    file.defs.map(&.qualified).should eq(["Outer::Inner.build", "Outer::Inner#run", "top"])
    file.defs[0].signature.should eq("def self.build(count : Int32) : Inner")
    file.defs[1].signature.should eq(
      %(def run(*args, key : String = "k", &block : Int32 -> Nil) : Nil)
    )
    file.defs[2].signature.should eq("def top")
  end

  it "keeps the nilable shorthand and external parameter names" do
    file = index("def load(from path : String, limit : Int32? = nil) : File?\nend\n")
    file.defs[0].signature.should eq("def load(from path : String, limit : Int32? = nil) : File?")
    file.defs[0].return_type.should eq(
      Heucristic::Syntax::Nilable.new(Heucristic::Syntax::Named.new(["File"], false))
    )
  end

  it "records the name span in zero based utf16 coordinates" do
    file = index("class A\n  def go\n  end\nend\n")
    file.defs[0].name_span.should eq(Heucristic::Document::Span.new(1, 6, 1, 8))
  end
end

describe Heucristic::Index::Arity do
  it "accepts counts within the required and optional range" do
    arity = Heucristic::Index::Arity.new(1, 1, false)
    arity.accepts?(0).should be_false
    arity.accepts?(1).should be_true
    arity.accepts?(2).should be_true
    arity.accepts?(3).should be_false
  end

  it "accepts any count at or above required with a splat" do
    Heucristic::Index::Arity.new(1, 0, true).accepts?(9).should be_true
  end
end

describe Heucristic::Index::Collector, "namespaces" do
  source = <<-CR
    module Outer
      abstract class Base(T) < Reference
        include Comparable(Base(T))
        extend Enumerable(T)

        @items : Array(T)

        def initialize
          @count : Int32 = 0
        end
      end

      struct Point
      end

      enum Colour : UInt8
        Red
      end

      alias Pair = Tuple(Int32, Int32)
    end

    lib LibC
    end

    class Outer::Base(T)
    end

    class ::Global
    end
    CR

  it "records every namespace with its lexically qualified name" do
    file = index(source)
    file.namespaces.map(&.name).should eq(
      ["Outer", "Outer::Base", "Outer::Point", "Outer::Colour", "LibC", "Outer::Base", "Global"]
    )
  end

  it "keeps a reopened class as a second entry" do
    file = index(source)
    classes = file.namespaces.select(Heucristic::Index::ClassNamespace)
    classes.count(&.name.==("Outer::Base")).should eq(2)
  end

  it "records class details" do
    base = index(source).namespaces.select(Heucristic::Index::ClassNamespace).first
    base.abstract_type.should be_true
    base.kind.class?.should be_true
    base.type_vars.should eq(["T"])
    base.superclass.to_s.should eq("Reference")
  end

  it "records a struct and an enum base type" do
    namespaces = index(source).namespaces
    point = namespaces.select(Heucristic::Index::ClassNamespace).find!(&.name.==("Outer::Point"))
    point.kind.struct?.should be_true
    namespaces.select(Heucristic::Index::EnumNamespace).first.base_type.to_s.should eq("UInt8")
  end

  it "records includes and extends against their owner" do
    mixins = index(source).mixins
    mixins.map { |mixin| {mixin.owner, mixin.kind, mixin.target.to_s} }.should eq([
      {"Outer::Base", Heucristic::Index::MixinKind::Include, "Comparable(Base(T))"},
      {"Outer::Base", Heucristic::Index::MixinKind::Extend, "Enumerable(T)"},
    ])
  end

  it "records instance variable declarations from the body and from initialize" do
    ivars = index(source).instance_vars
    ivars.map { |ivar| {ivar.owner, ivar.name, ivar.type.to_s} }.should eq([
      {"Outer::Base", "@items", "Array(T)"},
      {"Outer::Base", "@count", "Int32"},
    ])
  end

  it "records aliases" do
    aliases = index(source).aliases
    aliases.map { |entry| {entry.name, entry.target.to_s} }.should eq(
      [{"Outer::Pair", "Tuple(Int32, Int32)"}]
    )
  end

  it "attributes defs to the qualified owner" do
    index(source).defs.map(&.qualified).should eq(["Outer::Base#initialize"])
  end
end
