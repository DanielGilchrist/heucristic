require "../src/heucristic/index/loader"
require "../src/heucristic/index/shim_coverage"
require "../src/heucristic/index/shims"
require "../src/heucristic/index/workspace"
require "../src/heucristic/crystal_env"
require "../src/heucristic/server/shim_roots"
require "./shims_check/coverage"
require "./shims_check/verify"

module ShimsCheck
  extend self

  def run(args : Array(String)) : Int32
    roots = Heucristic::CrystalEnv.source_paths(Dir.current)
    if roots.is_a?(Heucristic::CrystalEnv::Unavailable)
      STDERR.puts roots.reason
      return 1
    end

    version = Heucristic::CrystalEnv.version
    if version.is_a?(Heucristic::CrystalVersion::Unknown)
      STDERR.puts version.reason
      return 1
    end

    events = Channel(Heucristic::Index::Event).new(64)
    shim_roots = Heucristic::Server::ShimRoots.for(Dir.current)
    Heucristic::Fibers.detach(:indexer) do
      Heucristic::Index::Loader.load(roots, shim_roots, version, events)
    end
    finished = loop do
      event = events.receive
      break event if event.is_a?(Heucristic::Index::Finished)
    end

    stdlib = Hash(String, Heucristic::Index::Def).new
    by_shape = Hash(String, Array(Heucristic::Index::Def)).new
    finished.files.each do |file|
      file.defs.each do |entry|
        stdlib[entry.identity] = entry
        (by_shape[entry.shape] ||= Array(Heucristic::Index::Def).new) << entry
      end
    end
    shims = Heucristic::Index::Shims.new
    shims.replace_all(finished.shims)

    orphans = Array(String).new
    absent = Array(String).new
    applicable = Set(String).new
    redundant = Array(String).new
    duplicated = Array(String).new
    finished.files.select { |file| Heucristic::Index::Loader.generated?(file.path) }.each do |file|
      file.defs.each do |entry|
        source = stdlib[entry.identity]?
        next if source.nil? || Heucristic::Index::Loader.generated?(source.path)

        duplicated << "#{entry.identity}  also in #{source.path}"
      end
    end
    shims.each do |shim|
      target = stdlib[shim.identity]?
      target ||= by_shape[shim.shape]?.try do |candidates|
        candidates.find { |candidate| shims.find(candidate) == shim }
      end
      if target.nil? && !indexed_owner?(shim, finished.files, shim_roots)
        absent << "#{shim.identity}  (#{shim.path})"
      elsif target.nil?
        orphans << "#{shim.identity}  (#{shim.path})"
      elsif typed?(target) && !adds_block_type?(shim, target)
        redundant << "#{shim.identity}  stdlib says : #{target.return_type} (#{target.path})"
      end
      applicable << shim.identity if target
    end

    puts "shims: #{shims.size} from #{shim_roots.join(", ")}"
    report("orphans (no stdlib def with this identity)", orphans)
    report("redundant (stdlib now has a return type)", redundant)
    report("generated defs the stdlib now declares in source", duplicated)
    report("shims for shards this project does not install", absent)
    structural = orphans.empty? && redundant.empty? && duplicated.empty? ? 0 : 1
    return clean(structural, version) unless args.includes?("--verify")

    verified = Verify.run(finished.files, shims, applicable, shim_roots, version)
    clean(structural + verified, version)
  end

  private def clean(failures : Int32, version : Heucristic::CrystalVersion::Known) : Int32
    return 1 unless failures == 0

    Coverage.stamp(version)
    0
  end

  private def indexed_owner?(
    entry : Heucristic::Index::Def,
    files : Array(Heucristic::Index::File),
    shim_roots : Array(String),
  ) : Bool
    owner = entry.owner
    return true unless owner.is_a?(Heucristic::Index::Identity)

    head = owner.name.split("::").first
    files.any? do |file|
      next false if shim_roots.any? { |root| file.path.starts_with?(root + "/") }

      file.namespaces.any? { |namespace| namespace.name.split("::").first == head }
    end
  end

  private def typed?(target : Heucristic::Index::Def) : Bool
    !target.return_type.is_a?(Heucristic::Index::Unrestricted)
  end

  private def adds_block_type?(
    shim : Heucristic::Index::Def,
    target : Heucristic::Index::Def,
  ) : Bool
    shimmed = shim.parameters.find(&.kind.block?).try(&.restriction)
    original = target.parameters.find(&.kind.block?).try(&.restriction)
    shimmed.is_a?(Heucristic::Syntax::Type) && !original.is_a?(Heucristic::Syntax::Type)
  end

  private def report(title : String, lines : Array(String)) : Nil
    puts "#{title}: #{lines.size}"
    lines.sort.each { |line| puts "  #{line}" }
  end
end

exit ShimsCheck.run(ARGV)
