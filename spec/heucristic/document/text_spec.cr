require "../../spec_helper"

private def text(source : String) : Heucristic::Document::Text
  Heucristic::Document::Text.new(source)
end

private def position(line : Int32, character : Int32) : LSProtocol::Position
  LSProtocol::Position.new(line: line.to_u32, character: character.to_u32)
end

describe Heucristic::Document::Text do
  it "converts a position to a byte offset" do
    text("ab\ncd").offset(position(1, 1)).should eq(4)
  end

  it "counts astral characters as two utf16 units" do
    text("😀x").offset(position(0, 2)).should eq(4)
  end

  it "clamps a character past the end of the line" do
    text("ab\ncd").offset(position(0, 10)).should eq(2)
  end

  it "reports a line past the end of the document" do
    text("ab").offset(position(3, 0)).should be_a(Heucristic::Document::OutOfRange)
  end

  it "converts a position to a one based codepoint point" do
    text("é_x\n").point(position(0, 2)).should eq(Heucristic::Document::Point.new(1, 3))
  end

  it "converts a point back to a utf16 position" do
    converted = text("😀x").position(Heucristic::Document::Point.new(1, 2))
    converted.should be_a(LSProtocol::Position)
    coordinates = converted.as?(LSProtocol::Position).try { |value| {value.line, value.character} }
    coordinates.should eq({0_u32, 2_u32})
  end

  it "splices a replacement into the source" do
    text("hello world").splice(6, 11, "there").source.should eq("hello there")
  end

  it "handles crlf line endings" do
    text("ab\r\ncd").offset(position(1, 0)).should eq(4)
  end
end
