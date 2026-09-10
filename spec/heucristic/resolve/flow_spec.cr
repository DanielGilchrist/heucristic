require "../../spec_helper"

private SOURCE = <<-CR
  class Base
  end

  class Path < Base
    def names : Array(String)
    end
  end

  class Union < Base
    def types : Array(Base)
    end
  end

  class Reader
    def read(node : Base, maybe : Path?, flag : Bool?, other : Path?) : Nil
      maybe.size if maybe
      maybe.size unless maybe
      maybe.size if maybe.nil?
      maybe.size unless maybe.nil?
      node.size if node.is_a?(Path)
      node.size unless node.is_a?(Path)
      node.size if !node.is_a?(Path)
      maybe.size if maybe && other
      other.size if maybe.nil? || other.nil?
      if (found = lookup)
        found.size
      end
      case node
      when Path  then node.size
      when Union then node.size
      else            node.size
      end
      case node
      when Path, Union then node.size
      end
      case maybe
      in Nil  then maybe.size
      in Path then maybe.size
      end
      while maybe
        maybe.size
      end
      flag.size if flag
      flag.size unless flag
      return unless other
      other.size
      raise "x" if node.is_a?(Union)
      node.size
      node || raise "gone"
      node.size
      later = 1
      later = "s"
      later.size
      maybe = other
      maybe.size
    end

    def lookup : Path?
    end
  end
  CR

private def narrowed(line_text : String, occurrence : Int32 = 1) : String
  lines = SOURCE.lines
  seen = 0
  exact = line_text.ends_with?("\n")
  needle = line_text.strip
  lines.each_with_index do |line, index|
    next unless exact ? line.strip == needle : line.includes?(needle)
    seen += 1
    next unless seen == occurrence

    column = line.index!(needle) + needle.rindex!("size") + 1
    return receiver_at(SOURCE, index + 1, column)
  end
  raise "no line #{line_text.inspect}"
end

describe Heucristic::Resolve::Flow do
  it "if x removes Nil in the then branch, unless x keeps only Nil" do
    narrowed("maybe.size if maybe\n").should eq("Path")
    narrowed("maybe.size unless maybe\n").should eq("Nil")
  end

  it "x.nil? narrows to Nil and its negation removes Nil" do
    narrowed("maybe.size if maybe.nil?").should eq("Nil")
    narrowed("maybe.size unless maybe.nil?").should eq("Path")
  end

  it "x.is_a?(T) narrows a supertype to T and its negation keeps the original" do
    narrowed("node.size if node.is_a?(Path)").should eq("Path")
    narrowed("node.size unless node.is_a?(Path)").should eq("Base")
    narrowed("node.size if !node.is_a?(Path)").should eq("Base")
  end

  it "&& narrows in the then branch and || in the else branch" do
    narrowed("maybe.size if maybe && other").should eq("Path")
    narrowed("other.size if maybe.nil? || other.nil?").should eq("Path | Nil")
  end

  it "an assignment in the condition types and narrows the variable" do
    narrowed("found.size").should eq("Path")
  end

  it "case when T narrows per branch and else removes every branch type" do
    narrowed("when Path  then node.size").should eq("Path")
    narrowed("when Union then node.size").should eq("Union")
    narrowed("else            node.size").should eq("Base")
  end

  it "when A, B narrows to the union of the branch types" do
    narrowed("when Path, Union then node.size").should eq("Path | Union")
  end

  it "case in narrows a union member by member" do
    narrowed("in Nil  then maybe.size").should eq("Nil")
    narrowed("in Path then maybe.size").should eq("Path")
  end

  it "while x narrows inside the loop" do
    narrowed("  maybe.size\n", 1).should eq("Path")
  end

  it "keeps Bool on a falsey branch because false is falsey" do
    narrowed("flag.size if flag").should eq("Bool")
    narrowed("flag.size unless flag").should eq("Bool | Nil")
  end

  it "an early return unless x narrows everything after it" do
    narrowed("other.size\n").should eq("Path")
  end

  it "a raise if x.is_a?(T) removes T after it" do
    narrowed("node.size\n", 1).should eq("Base")
  end

  it "x || raise makes x truthy after it" do
    narrowed("node.size\n", 2).should eq("Base")
  end

  it "the latest assignment before the reference wins" do
    narrowed("later.size").should eq("String")
    narrowed("maybe.size\n", 2).should eq("Path")
  end
end

describe Heucristic::Resolve::Flow, "inside blocks" do
  source = <<-CR
    module Enumerable(T)
      def find(& : T ->) : T?
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Node
      def args : Array(String)
      end
    end

    class Finder
      def find(node : Node?, name : String) : Nil
        return unless node
        node.args.find { |arg| arg.size }
      end
    end
    CR

  it "keeps guards in force when typing a block parameter's call" do
    receiver_of_size(source, "node.args.find { |arg| arg.size }").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "records, defaults, tuples and try" do
  source = <<-CR
    class Hash(K, V)
      def each(& : Tuple(K, V) ->) : Nil
      end
    end

    class Object
      def try(& : self -> U) : U forall U
      end
    end

    struct Nil
      def try(&block : NoReturn -> U) : Nil forall U
      end
    end

    class String
      def upcase : String
      end
    end

    module Index
      record Def, name : String do
        def label : Nil
          name.size
        end
      end
    end

    class Store
      def initialize(@counts = Hash(String, Int32).new, @label : String? = nil) : Nil
      end

      def run(word : String?) : Nil
        @counts.size
        @counts.each { |key, count| count.size }
        @counts.each { |key, count| key.size }
        word.try { |present| present.size }
        word.try(&.upcase).size
      end
    end
    CR

  it "treats a record body as the record's own scope" do
    receiver_of_size(source, "name.size").should eq("String")
  end

  it "declares an ivar from a parameter default when there is no restriction" do
    receiver_of_size(source, "@counts.size").should eq("Hash(String, Int32)")
  end

  it "splats a yielded tuple across block parameters" do
    receiver_of_size(source, "count.size").should eq("Int32")
    receiver_of_size(source, "key.size").should eq("String")
  end

  it "drops NoReturn so try yields the non nil member and returns a nilable result" do
    receiver_of_size(source, "present.size").should eq("String")
    receiver_of_size(source, "word.try(&.upcase).size").should eq("String | Nil")
  end
end

describe Heucristic::Resolve::Receiver, "unpacking, yields, super, named arguments and class" do
  source = <<-CR
    class Hash(K, V)
      def each(& : Tuple(K, V) ->) : Nil
      end

      def each_with_index(& : Tuple(K, V), Int32 ->) : Nil
      end
    end

    class Object
      def class
      end
    end

    class Array(T)
      def compact
      end

      def each(& : T ->) : Nil
      end
    end

    class Bag
      def initialize(@items : Array(String)) : Nil
      end

      def each_item(&) : Nil
        @items.each { |item| yield item, 1 }
      end
    end

    class Base
      def describe(count : Int32) : String
      end
    end

    class Child < Base
      def initialize(count : Int32) : Nil
        super.size
      end

      def describe(count : Int32) : String
        super.size
        super(count).size
        ""
      end
    end

    class Boxes
      def wrap(value : T, *, label : L) : Tuple(T, L) forall T, L
      end
    end

    class Runner
      def run(counts : Hash(String, Int32), bag : Bag, words : Array(String?), boxes : Boxes) : Nil
        counts.each_with_index { |(key, value), position| key.size }
        counts.each_with_index { |(key, value), position| value.size }
        counts.each_with_index { |(key, value), position| position.size }
        bag.each_item { |item, number| item.size }
        bag.each_item { |item, number| number.size }
        words.compact.size
        counts.class.size
        boxes.wrap(1, label: "a").size
      end
    end
    CR

  it "types unpacked block parameters from the yielded tuple" do
    each = "counts.each_with_index { |(key, value), position| "
    receiver_of_size(source, "#{each}key.size }").should eq("String")
    receiver_of_size(source, "#{each}value.size }").should eq("Int32")
    receiver_of_size(source, "#{each}position.size }").should eq("Int32")
  end

  it "types block parameters of a project def from its yield expressions" do
    receiver_of_size(source, "bag.each_item { |item, number| item.size }").should eq("String")
    receiver_of_size(source, "bag.each_item { |item, number| number.size }").should eq("Int32")
  end

  it "types super through the ancestor's def and as Nil inside initialize" do
    receiver_of_size(source, "super(count).size").should eq("String")
    lines = source.lines
    first = lines.index!(&.includes?("super.size")) + 1
    second = lines.rindex!(&.includes?("super.size")) + 1
    receiver_at(source, first, lines[first - 1].index!("size") + 1).should eq("Nil")
    receiver_at(source, second, lines[second - 1].index!("size") + 1).should eq("String")
  end

  it "removes Nil from the element type of Array#compact" do
    receiver_of_size(source, "words.compact.size").should eq("Array(String)")
  end

  it "answers the receiver's metaclass for Object#class" do
    receiver_of_size(source, "counts.class.size").should eq("Hash(String, Int32).class")
  end

  it "binds free variables from named arguments" do
    receiver_of_size(source, %(boxes.wrap(1, label: "a").size)).should eq("Tuple(Int32, String)")
  end
end

describe Heucristic::Resolve::Receiver, "implicit case objects" do
  source = <<-CR
    enum Kind
      Small
      Large
    end

    class Sizer
      def label(kind : Kind, name : String?) : Nil
        case kind
        when .small? then 1
        when .large? then 2
        end
        case name
        when .nil?  then 3
        when .size then 4
        end
      end
    end
    CR

  it "types the implicit object of a when branch as the case subject" do
    receiver_of_size(source, "when .size then 4").should eq("String | Nil")
    lines = source.lines
    line = lines.index!(&.includes?("when .small?")) + 1
    receiver_at(source, line, lines[line - 1].index!("small?") + 1).should eq("Kind")
  end
end

describe Heucristic::Resolve::Flow, "case on an assignment" do
  source = <<-CR
    class Failure
    end

    class Parser
      def parse : Int32 | Failure
      end

      def run : Nil
        case parsed = parse
        in Int32   then parsed.size
        in Failure then parsed.size
        end
      end
    end
    CR

  it "narrows the assigned variable per branch" do
    receiver_of_size(source, "in Int32   then parsed.size").should eq("Int32")
    receiver_of_size(source, "in Failure then parsed.size").should eq("Failure")
  end
end
