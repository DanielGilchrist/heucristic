require "../../spec_helper"
require "file_utils"

private FILLER_COUNT = 60

private def write_shim(root : String, name : String, return_type : String) : Nil
  File.write(File.join(root, name), <<-CR)
    class Greeter
      def greet(name : String) : #{return_type}
      end
    end
    CR
end

private def finished_shims(roots : Array(String)) : Array(Heucristic::Index::File)
  events = Channel(Heucristic::Index::Event).new(256)
  Heucristic::Index::Loader.load(Array(String).new, roots, SPEC_CRYSTAL, events)
  loop do
    event = events.receive
    return event.shims if event.is_a?(Heucristic::Index::Finished)
  end
end

private def unannotated_greet : Heucristic::Index::Def
  source = "class Greeter\n  def greet(name : String)\n  end\nend\n"
  tree = Heucristic::Syntax.parse(source, "greeter.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  file = Heucristic::Index::Collector.collect(
    "greeter.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
  )
  file.defs.find!(&.name.==("greet"))
end

describe Heucristic::Index::Loader do
  it "hands shims over in root order so a later root wins by identity" do
    base = File.join(Dir.tempdir, "heucristic-spec-loader-#{Process.pid}")
    embedded = File.join(base, "embedded")
    project = File.join(base, "project")
    Dir.mkdir_p(embedded)
    Dir.mkdir_p(project)
    begin
      FILLER_COUNT.times { |index| write_shim(embedded, "filler_#{index}.cr", "Int32") }
      write_shim(project, "greeter.cr", "String")

      20.times do
        shims = Heucristic::Index::Shims.new
        shims.replace_all(finished_shims([embedded, project]))
        shims.find(unannotated_greet).try(&.return_type.to_s).should eq("String")
      end
    ensure
      FileUtils.rm_rf(base)
    end
  end
end
