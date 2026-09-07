require "../../spec_helper"

private def partial(
  start_line : Int32,
  start_character : Int32,
  end_line : Int32,
  end_character : Int32,
  replacement : String,
) : LSProtocol::TextDocumentContentChangeEvent
  LSProtocol::TextDocumentContentChangePartial.new(
    range: LSProtocol::Range.new(
      start: LSProtocol::Position.new(line: start_line.to_u32, character: start_character.to_u32),
      end: LSProtocol::Position.new(line: end_line.to_u32, character: end_character.to_u32),
    ),
    text: replacement,
  )
end

describe Heucristic::Document::Edit do
  it "applies a partial change" do
    text = Heucristic::Document::Text.new("def foo\nend\n")
    result = Heucristic::Document::Edit.apply(text, partial(0, 4, 0, 7, "bar"))
    result.should be_a(Heucristic::Document::Text)
    result.as?(Heucristic::Document::Text).try(&.source).should eq("def bar\nend\n")
  end

  it "applies changes in order" do
    text = Heucristic::Document::Text.new("ab")
    changes = [partial(0, 1, 0, 1, "X"), partial(0, 2, 0, 2, "Y")]
    result = Heucristic::Document::Edit.apply_all(text, changes)
    result.as?(Heucristic::Document::Text).try(&.source).should eq("aXYb")
  end

  it "replaces the whole document" do
    text = Heucristic::Document::Text.new("ab")
    whole = LSProtocol::TextDocumentContentChangeWholeDocument.new(text: "z")
    result = Heucristic::Document::Edit.apply(text, whole)
    result.as?(Heucristic::Document::Text).try(&.source).should eq("z")
  end

  it "reports a change outside the document" do
    text = Heucristic::Document::Text.new("ab")
    result = Heucristic::Document::Edit.apply(text, partial(5, 0, 5, 0, "x"))
    result.should be_a(Heucristic::Document::OutOfRange)
  end
end
