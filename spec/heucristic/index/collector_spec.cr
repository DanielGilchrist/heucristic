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
    index(source).defs.map(&.qualified).should eq(["Outer::Base#initialize", "Outer::Colour#red?"])
  end
end

describe Heucristic::Index::Collector, "record" do
  source = <<-CR
    module M
      record Point, x : Int32, label : String = "p", y = 1 do
        def sum : Int32
          x + y
        end
      end
    end
    CR

  it "indexes a record as a struct namespace" do
    point = index(source).namespaces.select(Heucristic::Index::ClassNamespace).first
    point.name.should eq("M::Point")
    point.kind.struct?.should be_true
  end

  it "indexes typed fields as instance variables and getters" do
    file = index(source)
    file.instance_vars.map { |ivar| {ivar.name, ivar.type.to_s} }.should eq(
      [{"@x", "Int32"}, {"@label", "String"}]
    )
    getters = file.defs.select(&.parameters.empty?).map do |entry|
      {entry.qualified, entry.return_type.to_s}
    end
    getters.should eq(
      [{"M::Point#x", "Int32"}, {"M::Point#label", "String"}, {"M::Point#sum", "Int32"}]
    )
  end

  it "leaves an untyped field out of the index" do
    index(source).instance_vars.map(&.name).should_not contain("@y")
  end
end

describe Heucristic::Index::Collector, "instance variables from parameters" do
  it "declares an ivar from a typed @-parameter and records an untyped one as unsupported" do
    file = index("class C\n  def initialize(@a : Int32, @b, c : String) : Nil\n  end\nend\n")
    typed = file.instance_vars.map { |ivar| {ivar.name, ivar.type.is_a?(Heucristic::Syntax::Type)} }
    typed.should eq([{"@a", true}, {"@b", false}])
  end
end

describe Heucristic::Index::Collector, "instance variables from assignments" do
  source = <<-CR
    class Session
      def initialize : Nil
        @store = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @names = [] of String
        @lookup = {} of String => Int32
        @count = 0
        @label = "x"
        @flag = true
        @maybe = nil
        @kind = Kind
        @narrowed = thing.as(String)
        @optional = thing.as?(String)
        @computed = build
        @declared : Int32 = 1
      end
    end
    CR

  it "types an ivar from an evident right hand side, and keeps a call result as a site" do
    file = index(source)
    typed = file.instance_vars.map do |ivar|
      type = ivar.type
      text = type.is_a?(Heucristic::Syntax::TypeReader::Unsupported) ? "?#{type.source}" : type.to_s
      {ivar.name, text, ivar.origin}
    end
    typed.should eq([
      {"@store", "Document::Store", Heucristic::Index::Origin::Assigned},
      {"@trees", "Hash(String, Crystal::ASTNode)", Heucristic::Index::Origin::Assigned},
      {"@names", "::Array(String)", Heucristic::Index::Origin::Assigned},
      {"@lookup", "::Hash(String, Int32)", Heucristic::Index::Origin::Assigned},
      {"@count", "::Int32", Heucristic::Index::Origin::Assigned},
      {"@label", "::String", Heucristic::Index::Origin::Assigned},
      {"@flag", "::Bool", Heucristic::Index::Origin::Assigned},
      {"@maybe", "::Nil", Heucristic::Index::Origin::Assigned},
      {"@kind", "Kind.class", Heucristic::Index::Origin::Assigned},
      {"@narrowed", "String", Heucristic::Index::Origin::Assigned},
      {"@optional", "String?", Heucristic::Index::Origin::Assigned},
      {"@computed", "?build", Heucristic::Index::Origin::Assigned},
      {"@declared", "Int32", Heucristic::Index::Origin::Declared},
    ])
  end
end

describe Heucristic::Index::Collector, "constants" do
  it "records constants with their qualified name and evident type" do
    file = index("module Fibers\n  WORKERS = 4\n  NAME = compute\nend\nTOP = \"t\"\n")
    recorded = file.constants.map { |constant| {constant.name, constant.value, constant.type.to_s} }
    recorded.should eq([
      {"Fibers::WORKERS", "4", "::Int32"},
      {"Fibers::NAME", "compute", "Heucristic::Index::Evident::NotEvident()"},
      {"TOP", "\"t\"", "::String"},
    ])
  end
end

describe Heucristic::Index::Collector, "enum members" do
  it "declares a predicate def per member" do
    file = index("enum Receiver\n  Instance\n  Metaclass\n  BlinkFast\nend\n")
    predicates = file.defs.map { |entry| {entry.qualified, entry.signature} }
    predicates.should eq([
      {"Receiver#instance?", "def instance? : ::Bool"},
      {"Receiver#metaclass?", "def metaclass? : ::Bool"},
      {"Receiver#blink_fast?", "def blink_fast? : ::Bool"},
    ])
  end

  it "records each member as a constant typed as the enum" do
    file = index("module M\n  enum Kind\n    Splat\n    Block = 4\n  end\nend\n")
    recorded = file.constants.map do |constant|
      {constant.name, constant.value.to_s, constant.type.to_s}
    end
    recorded.should eq([
      {"M::Kind::Splat", "Heucristic::Index::Constant::ImplicitValue()", "M::Kind"},
      {"M::Kind::Block", "4", "M::Kind"},
    ])
  end
end

describe Heucristic::Index::Collector, "accessor macros" do
  source = <<-CR
    class Node
      getter args : Array(Int32)
      getter? done : Bool
      property name : String = "n"
      setter count : Int32
      getter label
      getter :sym
      class_getter registry : Hash(String, Int32)
      property size = 3

      record Pair, a : Int32 do
        def self.zero : Pair
        end
      end
    end
    CR

  it "declares reader and writer defs with the field type" do
    file = index(source)
    defs = file.defs.map { |entry| {entry.qualified, entry.signature} }
    defs.should contain({"Node#args", "def args : Array(Int32)"})
    defs.should contain({"Node#done?", "def done? : Bool"})
    defs.should contain({"Node#name", "def name : String"})
    defs.should contain({"Node#name=", "def name=(value : String) : String"})
    defs.should contain({"Node#count=", "def count=(value : Int32) : Int32"})
    defs.should contain({"Node#label", "def label"})
    defs.should contain({"Node#sym", "def sym"})
    defs.should contain({"Node.registry", "def self.registry : Hash(String, Int32)"})
    defs.should contain({"Node#size", "def size : ::Int32"})
    defs.should contain({"Node::Pair.zero", "def self.zero : Pair"})
  end

  it "declares the backing instance variable for typed instance accessors" do
    ivars = index(source).instance_vars.map { |ivar| {ivar.name, ivar.type.to_s} }
    ivars.should contain({"@args", "Array(Int32)"})
    ivars.should contain({"@name", "String"})
    ivars.map(&.[0]).should_not contain("@registry")
  end
end

describe Heucristic::Index::Collector, "delegate" do
  it "declares a forwarding def per delegated name" do
    source = <<-CR
      class Config
        delegate :token, :save!, to: current
        delegate name, to: @inner
      end
      CR
    file = index(source)
    forwards = file.defs.map { |entry| {entry.qualified, entry.forwards_to.to_s} }
    forwards.should eq([
      {"Config#token", "current"}, {"Config#save!", "current"}, {"Config#name", "@inner"},
    ])
  end
end

describe Heucristic::Index::Collector, "explicit receivers" do
  it "files a def with a type receiver under that type" do
    source = <<-CR
      def Object.from_yaml(source : String) : self
      end

      module M
        def Codec.parse : Nil
        end
      end
      CR
    file = index(source)
    file.defs.map(&.qualified).should eq(["Object.from_yaml", "M::Codec.parse"])
  end
end

describe Heucristic::Index::Collector, "macro regions" do
  source = <<-CR
    class File
      {% begin %}
        def self.read(
          name : String,
          {% if compare_versions(Crystal::VERSION, "1.5.0") >= 0 %} @[Deprecated] {% end %}
          blocking = nil
        ) : String
        end
      {% end %}

      {% if flag?(:win32) %}
        def self.windows_only : Nil
        end
      {% else %}
        def self.elsewhere : Nil
        end
      {% end %}

      {% unless flag?(:win32) %}
        def self.posix : Nil
        end
      {% end %}

      {% if flag?(:mystery) %}
        def self.undecidable : Nil
        end
      {% end %}
    end
    CR

  it "collects defs from macro regions whose conditions it can decide for this host" do
    names = index(source).defs.map(&.qualified)
    names.should contain("File.read")
    names.should contain("File.elsewhere")
    names.should contain("File.posix")
    names.should_not contain("File.windows_only")
    names.should_not contain("File.undecidable")
  end

  it "keeps absolute locations for defs inside macro regions" do
    read = index(source).defs.find!(&.name.==("read"))
    read.name_span.start_line.should eq(2)
    read.signature.should eq("def self.read(name : String, blocking = nil) : String")
  end
end
