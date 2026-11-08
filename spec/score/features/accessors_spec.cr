require "../../spec_helper"
require "../../../tools/score/features/accessors"

private def span_at(line : Int32, column : Int32, size : Int32) : Heucristic::Document::Span
  Heucristic::Document::Span.new(line.to_u32, column.to_u32, line.to_u32, (column + size).to_u32)
end

private def accessors_over(source : String, & : Score::Features::Accessors, String ->) : Nil
  file = File.tempfile("accessors", ".cr") { |io| io << source }
  yield Score::Features::Accessors.new, file.path
ensure
  file.try(&.delete)
end

describe Score::Features::Accessors do
  it "finds a field on a continuation line of a multi-line record call" do
    source = "record Outcome,\n  path : String,\n  skipped : Skipped? = nil do\nend\n"
    accessors_over(source) do |accessors, path|
      accessors.declares?(path, span_at(2, 2, 7)).should be_true
    end
  end

  it "does not claim a name outside a declaration macro" do
    source = "class A\n  def run\n    skipped = 1\n  end\nend\n"
    accessors_over(source) do |accessors, path|
      accessors.declares?(path, span_at(2, 4, 7)).should be_false
    end
  end
end
