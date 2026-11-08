require "../../spec_helper"
require "../../../tools/score/features/walker"

private SOURCE = <<-CRYSTAL
  require "./other"

  alias Name = String

  enum Color
    Red
  end

  module Outer::Inner
    LIMIT = 1

    class Widget < Base
      @count : Int32 = 0
      @@total = 0

      def initialize(@label : String, size : Int32 = 1)
      end

      def run(items : Array(Foo)) : Bool
        value = items.size
        items.each { |item| puts item }
        pairs.each { |(a, b)| a + b }
        helper(self)
        @count + @@total
        Foo::Bar.new
        getter other : Int32
        value
      end
    end
  end
  CRYSTAL

private def sites_of(source : String) : Array(Score::Features::Site)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "syntax error" unless tree.is_a?(Crystal::ASTNode)

  Score::Features::Walker.sites(tree, source)
end

private def kinds_at(
  sites : Array(Score::Features::Site),
  line : Int32,
  name : String,
) : Array(Score::Features::Kind)
  sites.select { |site| site.line == line && site.name == name }.map(&.kind)
end

describe Score::Features::Walker do
  sites = sites_of(SOURCE)

  it "records a require string at the statement" do
    sites.first.should eq Score::Features::Site.new(:require, 1, 1, "./other")
  end

  it "separates declaration paths from type paths and constant paths" do
    kinds_at(sites, 3, "Name").should eq [Score::Features::Kind::DeclarationPath]
    kinds_at(sites, 3, "String").should eq [Score::Features::Kind::TypePath]
    kinds_at(sites, 9, "Outer").should eq [Score::Features::Kind::DeclarationPath]
    kinds_at(sites, 9, "Inner").should eq [Score::Features::Kind::DeclarationPath]
    kinds_at(sites, 10, "LIMIT").should eq [Score::Features::Kind::DeclarationPath]
    kinds_at(sites, 12, "Base").should eq [Score::Features::Kind::TypePath]
    kinds_at(sites, 25, "Foo").should eq [Score::Features::Kind::ConstantPath]
    kinds_at(sites, 25, "Bar").should eq [Score::Features::Kind::ConstantPath]
  end

  it "puts every segment of a path at its own column" do
    bar = sites.find { |site| site.name == "Bar" }
    bar.should eq Score::Features::Site.new(:constant_path, 25, 12, "Bar")
  end

  it "records enum members apart from parameters" do
    kinds_at(sites, 6, "Red").should eq [Score::Features::Kind::EnumMember]
  end

  it "records instance and class variables" do
    kinds_at(sites, 13, "@count").should eq [Score::Features::Kind::InstanceVar]
    kinds_at(sites, 14, "@@total").should eq [Score::Features::Kind::ClassVar]
    kinds_at(sites, 24, "@count").should eq [Score::Features::Kind::InstanceVar]
    kinds_at(sites, 24, "@@total").should eq [Score::Features::Kind::ClassVar]
  end

  it "records def names, parameters and instance variable parameters" do
    kinds_at(sites, 16, "initialize").should eq [Score::Features::Kind::DefName]
    kinds_at(sites, 16, "@label").should eq [Score::Features::Kind::InstanceVarParameter]
    kinds_at(sites, 16, "size").should eq [Score::Features::Kind::Parameter]
    kinds_at(sites, 19, "items").should eq [Score::Features::Kind::Parameter]
  end

  it "separates local definitions from uses" do
    kinds_at(sites, 20, "value").should eq [Score::Features::Kind::LocalDefinition]
    kinds_at(sites, 20, "items").should eq [Score::Features::Kind::LocalUse]
    kinds_at(sites, 27, "value").should eq [Score::Features::Kind::LocalUse]
  end

  it "records calls with and without a receiver" do
    kinds_at(sites, 20, "size").should eq [Score::Features::Kind::CallWithReceiver]
    kinds_at(sites, 21, "puts").should eq [Score::Features::Kind::StatementCall]
    kinds_at(sites, 22, "pairs").should eq [Score::Features::Kind::CallImplicit]
    kinds_at(sites, 23, "helper").should eq [Score::Features::Kind::CallImplicit]
    kinds_at(sites, 25, "new").should eq [Score::Features::Kind::CallWithReceiver]
  end

  it "records declaration macros and statements apart from method calls" do
    kinds_at(sites, 26, "getter").should eq [Score::Features::Kind::StatementCall]
  end

  it "records block parameters, plain and unpacked" do
    kinds_at(sites, 21, "item").should eq [
      Score::Features::Kind::BlockParameter, Score::Features::Kind::LocalUse,
    ]
    kinds_at(sites, 22, "a").should eq [
      Score::Features::Kind::UnpackedBlockParameter, Score::Features::Kind::LocalUse,
    ]
  end

  it "records self" do
    kinds_at(sites, 23, "self").should eq [Score::Features::Kind::SelfReference]
  end
end

describe Score::Features::Walker do
  it "records a rescue clause's variable as a local definition at its own column" do
    rescued = sites_of("def run\n  exit\nrescue error : Exception\n  error\nend\n")
    rescued.should contain Score::Features::Site.new(:local_definition, 3, 8, "error")
    kinds_at(rescued, 4, "error").should eq [Score::Features::Kind::LocalUse]
  end
end
