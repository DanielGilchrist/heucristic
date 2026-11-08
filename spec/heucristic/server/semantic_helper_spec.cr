require "../../spec_helper"
require "../../../src/heucristic/index/macro_output"

private HELPER  = File.expand_path("bin/heucristic-semantic")
private FIXTURE = File.expand_path("spec/fixtures/sites")

private def expanded : Heucristic::Index::MacroOutput
  crystal_path = IO::Memory.new
  Process.run("crystal", ["env", "CRYSTAL_PATH"], output: crystal_path)
  output = IO::Memory.new
  Process.run(
    HELPER,
    [File.join(FIXTURE, "src/main.cr"), FIXTURE],
    env: {"CRYSTAL_PATH" => crystal_path.to_s.strip},
    chdir: FIXTURE,
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
  else
    pending "needs bin/heucristic-semantic, built by script/build-semantic"
  end
end
