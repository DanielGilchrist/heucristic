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
