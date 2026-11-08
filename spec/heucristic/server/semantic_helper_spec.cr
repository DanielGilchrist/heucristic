require "../../spec_helper"
require "../../../src/heucristic/index/macro_output"

private HELPER     = File.expand_path("bin/heucristic-semantic")
private FIXTURE    = File.expand_path("spec/fixtures/sites")
private EXPANSIONS = File.expand_path("spec/fixtures/expansions")

private def expanded(fixture : String = FIXTURE) : Heucristic::Index::MacroOutput
  crystal_path = IO::Memory.new
  Process.run("crystal", ["env", "CRYSTAL_PATH"], output: crystal_path)
  output = IO::Memory.new
  Process.run(
    HELPER,
    [File.join(fixture, "src/main.cr"), fixture],
    env: {"CRYSTAL_PATH" => crystal_path.to_s.strip},
    chdir: fixture,
    output: output
  )
  Heucristic::Index::MacroOutput.from_json(output.to_s)
end

describe "the semantic helper's site table" do
  if File.exists?(HELPER)
    it "points each site at the line of the def it describes" do
      output = expanded
      lines = output.source.try(&.lines) || Array(String).new
      inner = output.sites.find { |site| site.name == "inner" }

      inner.should_not be_nil
      inner.try { |site| lines[site.line - 1].should contain("def inner") }
    end

    it "records a site on the declaration line of a type or constant a macro declares" do
      output = expanded
      lines = output.source.try(&.lines) || Array(String).new
      declared = output.sites.select { |site| site.name == "settings" }
      declaring = declared.map { |site| lines[site.line - 1] }

      declaring.should contain("class ::Mail::Inner")
      declaring.any?(&.starts_with?("::Mail::HABITAT")).should be_true
      declared.map(&.expanded_line).uniq!.should eq([13])
    end

    it "expands a macro called through an alias of its owner (crystal run: Slice(UInt8))" do
      found = expanded(EXPANSIONS).expansions.find { |expansion| expansion.name == "[]" }

      found.should_not be_nil
      found.try(&.source.should(contain("Slice(UInt8).new")))
    end
  else
    pending "needs bin/heucristic-semantic, built by script/build-semantic"
  end
end
