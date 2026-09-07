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
      %(def run(*args, key : String = "k", &block : (Int32 -> Nil)) : Nil)
    )
    file.defs[2].signature.should eq("def top")
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
