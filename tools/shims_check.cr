require "../src/heucristic/index/loader"
require "../src/heucristic/index/shims"
require "../src/heucristic/index/workspace"
require "../src/heucristic/crystal_env"
require "../src/heucristic/server/shim_roots"

module ShimsCheck
  extend self

  def run : Int32
    roots = Heucristic::CrystalEnv.source_paths(Dir.current)
    if roots.is_a?(Heucristic::CrystalEnv::Unavailable)
      STDERR.puts roots.reason
      return 1
    end

    events = Channel(Heucristic::Index::Event).new(64)
    shim_roots = Heucristic::Server::ShimRoots.for(Dir.current)
    spawn { Heucristic::Index::Loader.load(roots, shim_roots, events) }
    finished = loop do
      event = events.receive
      break event if event.is_a?(Heucristic::Index::Finished)
    end

    stdlib = Hash(String, Heucristic::Index::Def).new
    finished.files.each { |file| file.defs.each { |entry| stdlib[entry.identity] = entry } }
    shims = Heucristic::Index::Shims.new
    shims.replace_all(finished.shims)

    orphans = Array(String).new
    redundant = Array(String).new
    shims.each do |shim|
      target = stdlib[shim.entry.identity]?
      if target.nil?
        orphans << "#{shim.entry.identity}  (#{shim.entry.path})"
      elsif !target.return_type.is_a?(Heucristic::Index::Unrestricted)
        redundant << "#{shim.entry.identity}  stdlib says : #{target.return_type} (#{target.path})"
      end
    end

    puts "shims: #{shims.size} from #{shim_roots.join(", ")}"
    report("orphans (no stdlib def with this identity)", orphans)
    report("redundant (stdlib now has a return type)", redundant)
    orphans.empty? && redundant.empty? ? 0 : 1
  end

  private def report(title : String, lines : Array(String)) : Nil
    puts "#{title}: #{lines.size}"
    lines.sort.each { |line| puts "  #{line}" }
  end
end

exit ShimsCheck.run
