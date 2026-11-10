require "../../spec_helper"

private def parse_value(source : String) : Crystal::ASTNode
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::Assign)

  tree.value
end

private def point(line : Int32, column : Int32) : Heucristic::Document::Point
  Heucristic::Document::Point.new(line, column)
end

private def whole_of(
  node : Crystal::NumberLiteral | Crystal::StringLiteral | Crystal::StringInterpolation,
  source : String,
) : Heucristic::Syntax::LiteralExtent
  extent = Heucristic::Syntax::LiteralExtent.whole(node, source.lines)
  raise "unlocated" if extent.is_a?(Heucristic::Document::NoRegion)

  extent
end

describe Heucristic::Syntax::LiteralExtent do
  it "includes both ends of a node's location, because the compiler's end location is inclusive" do
    source = "x = 12\n"
    extent = whole_of(parse_value(source).as(Crystal::NumberLiteral), source)
    extent.includes?(point(1, 4)).should be_false
    extent.includes?(point(1, 5)).should be_true
    extent.includes?(point(1, 6)).should be_true
    extent.includes?(point(1, 7)).should be_false
  end

  it "spans lines for a multi-line string" do
    source = "x = \"ab\ncd\"\n"
    extent = whole_of(parse_value(source).as(Crystal::StringLiteral), source)
    extent.includes?(point(1, 8)).should be_true
    extent.includes?(point(2, 1)).should be_true
    extent.includes?(point(2, 3)).should be_true
    extent.includes?(point(2, 4)).should be_false
  end

  it "splits a heredoc into its opener and its body through the terminator" do
    source = "x = <<-X\n  hi\n  X\n"
    extent = whole_of(parse_value(source).as(Crystal::StringInterpolation), source)
    extent.regions.size.should eq(2)
    extent.includes?(point(1, 5)).should be_true
    extent.includes?(point(1, 8)).should be_true
    extent.includes?(point(1, 9)).should be_false
    extent.includes?(point(2, 1)).should be_true
    extent.includes?(point(3, 3)).should be_true
  end

  it "owns only an array's brackets" do
    source = "x = [1, 2]\n"
    node = parse_value(source).as(Crystal::ArrayLiteral)
    extent = Heucristic::Syntax::LiteralExtent.delimiters(node, source.lines)
    raise "unlocated" if extent.is_a?(Heucristic::Document::NoRegion)

    {5, 10}.each { |column| extent.includes?(point(1, column)).should be_true }
    {6, 7, 8, 9}.each { |column| extent.includes?(point(1, column)).should be_false }
  end

  it "owns an array's `of` keyword and the bracket before it" do
    source = "x = [ ] of Int64\n"
    node = parse_value(source).as(Crystal::ArrayLiteral)
    extent = Heucristic::Syntax::LiteralExtent.delimiters(node, source.lines)
    raise "unlocated" if extent.is_a?(Heucristic::Document::NoRegion)

    {5, 7, 9, 10}.each { |column| extent.includes?(point(1, column)).should be_true }
    {6, 8, 11}.each { |column| extent.includes?(point(1, column)).should be_false }
  end

  it "owns only a range's operator" do
    source = "x = 1 ... 3\n"
    node = parse_value(source).as(Crystal::RangeLiteral)
    extent = Heucristic::Syntax::LiteralExtent.delimiters(node, source.lines)
    raise "unlocated" if extent.is_a?(Heucristic::Document::NoRegion)

    {7, 8, 9}.each { |column| extent.includes?(point(1, column)).should be_true }
    {5, 6, 10, 11}.each { |column| extent.includes?(point(1, column)).should be_false }
  end

  it "reports a node without a location as unlocated" do
    unlocated = Crystal::NumberLiteral.new(1)
    extent = Heucristic::Syntax::LiteralExtent.whole(unlocated, Array(String).new)
    extent.should be_a(Heucristic::Document::NoRegion)
  end
end
