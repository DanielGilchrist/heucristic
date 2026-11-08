require "../../src/heucristic/index/shims"
require "../../src/heucristic/index/workspace"
require "../../src/heucristic/index/collector"
require "../../src/heucristic/index/generated"
require "../../src/heucristic/index/macro_site"
require "../../src/heucristic/server/shim_roots"
require "../../src/heucristic/server/macros"
require "../../src/heucristic/document/text"

module Score
  class Expansion
    getter origins = Hash(String, Heucristic::Index::MacroSite).new

    def initialize(
      @root : String,
      @events : Channel(Heucristic::Index::Event),
      @workspace : Heucristic::Index::Workspace,
      @shims : Heucristic::Index::Shims,
      @defines : Array(String),
    ) : Nil
    end

    def all : Hash(Heucristic::Index::MacroTarget, Set(String))?
      targets = Hash(Heucristic::Index::MacroTarget, Set(String)).new
      compiled = expand(:main)
      return unless compiled
      targets[Heucristic::Index::MacroTarget::Main] = compiled
      if Dir.exists?(File.join(@root, "spec"))
        from_specs = expand(:spec)
        targets[Heucristic::Index::MacroTarget::Spec] = from_specs if from_specs
      end

      loose = loose_files(targets)
      return targets if loose.empty?

      from_loose = expand(:loose, loose)
      targets[Heucristic::Index::MacroTarget::Loose] = from_loose if from_loose
      targets
    end

    private def loose_files(
      targets : Hash(Heucristic::Index::MacroTarget, Set(String)),
    ) : Array(String)
      loose = Array(String).new
      @workspace.each_file do |file|
        path = file.path
        next unless path.starts_with?(@root + "/")
        next if path.starts_with?(File.join(@root, "lib") + "/")
        next if path.starts_with?(File.join(@root, "spec") + "/")
        next if Heucristic::Index::MacroTarget.generated?(path)
        next if targets.each_value.any?(&.includes?(path))

        loose << path
      end
      loose
    end

    private def expand(
      target : Heucristic::Index::MacroTarget,
      loose : Array(String) = Array(String).new,
    ) : Set(String)?
      macros = Heucristic::Server::Macros.new(@events)
      macros.loose(loose)
      macros.defines(@defines)
      macros.start(@root, nil, target)
      result = loop do
        event = @events.receive
        break event unless event.is_a?(Heucristic::Index::MacrosStarted)
      end
      case result
      in Heucristic::Index::MacrosExpanded
        return merge(result, target)
      in Heucristic::Index::MacrosFailed
        puts "macros (#{target.wire}): failed (#{result.reason})"
      in Heucristic::Index::MacrosUnavailable
        puts "macros (#{target.wire}): unavailable (#{result.reason})"
      in Heucristic::Index::Started, Heucristic::Index::Advanced, Heucristic::Index::Finished,
         Heucristic::Index::MacrosStarted, Heucristic::Index::CompilerStarted,
         Heucristic::Index::CompilerFinished, Heucristic::Index::CompilerFailed,
         Heucristic::Index::CompilerUnavailable
        puts "macros: unexpected #{result.class.name}"
      end
      nil
    end

    private def merge(
      result : Heucristic::Index::MacrosExpanded,
      target : Heucristic::Index::MacroTarget,
    ) : Set(String)?
      path = target.generated_path
      tree = Heucristic::Syntax.parse(result.source, path)
      if tree.is_a?(Heucristic::Syntax::Broken)
        puts "macros (#{target.wire}): generated source does not parse: #{tree.message}"
        return
      end
      text = Heucristic::Document::Text.new(result.source)
      collected = Heucristic::Index::Collector.collect(path, text, tree, @workspace.crystal_version)
      loaded = Heucristic::Index::LoadedFiles.new(
        result.files.to_set, Heucristic::Server::ShimRoots.for(@root)
      )
      file = Heucristic::Index::Generated.merge(collected, result.sites, @workspace, @shims, loaded)
      @workspace.update(file)
      @workspace.expand(target, result.expansions)
      result.sites.each { |site| @origins["#{path}:#{site.line}"] = site }
      elapsed = result.elapsed.total_milliseconds.round
      puts "macros (#{target.wire}): #{file.defs.size} generated defs kept of " \
           "#{collected.defs.size} in #{elapsed}ms"
      result.excluded.each do |exclusion|
        relative = exclusion.path.sub(@root + "/", "")
        puts "macros (#{target.wire}): left out #{relative}: #{exclusion.summary}"
      end
      result.files.to_set
    end
  end
end
