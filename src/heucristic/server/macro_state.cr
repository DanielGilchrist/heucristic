require "../document/text"
require "../index/collector"
require "../index/event"
require "../index/generated"
require "../index/loaded_files"
require "../index/macro_site"
require "../index/macro_target"
require "../index/shims"
require "../index/workspace"
require "../protocol/encoder"
require "../protocol/transport"
require "../resolve/compiled"
require "../resolve/methods"
require "../syntax"
require "./macro_lookup"
require "./macro_status"
require "./macros"
require "./notice"
require "./project_files"
require "./resolver_caches"
require "./shim_roots"
require "./stage"

module Heucristic
  module Server
    class MacroState
      include MacroLookup

      def initialize(
        events : Channel(Index::Event),
        @transport : Protocol::Transport,
        @workspace : Index::Workspace,
        @shims : Index::Shims,
        @methods : Resolve::Methods,
        @caches : ResolverCaches,
      ) : Nil
        @runner = Macros.new(events)
        @status = MacrosPending.new
        @sites = Hash(String, Hash(Int32, Index::MacroSite)).new
        @generated = Hash(Index::MacroTarget, Index::File).new
        @compiled = Hash(Index::MacroTarget, Set(String)).new
        @spec_wanted = false
        @loose = Set(String).new
        @indexed = false
      end

      def defines(flags : Array(String)) : Nil
        @runner.defines(flags)
      end

      def done? : Bool
        @status.is_a?(MacrosDone)
      end

      def compiled_files : Set(String)
        all = Set(String).new
        @compiled.each_value { |files| all.concat(files) }
        all
      end

      def restore : Nil
        @generated.each_value { |file| @workspace.update(file) }
      end

      def indexed(root : String, semantic : String?) : Nil
        @indexed = true
        @runner.start(root, semantic, :main)
        @runner.start(root, semantic, :spec) if @spec_wanted
      end

      def saved(root : String, semantic : String?) : Nil
        @runner.start(root, semantic, :main)
        @runner.start(root, semantic, :spec) if @spec_wanted
        @runner.start(root, semantic, :loose) unless @loose.empty?
      end

      def opened(path : String, root : String, semantic : String?) : Nil
        want_spec(path, root, semantic)
        want_loose(path, root, semantic)
      end

      def started(event : Index::MacrosStarted) : Nil
        case event.target
        in .main?
          @status = MacrosPending.new
          notify
        in .spec?, .loose?
          notify_target(event.target, Stage::Pending, nil, 0)
        end
      end

      def expanded(
        event : Index::MacrosExpanded,
        root : String,
        semantic : String?,
        open_paths : Set(String),
      ) : Nil
        path = event.target.generated_path
        tree = Syntax.parse(event.source, path)
        if tree.is_a?(Syntax::Broken)
          broken(event.target, "generated source does not parse: #{tree.message}")
          return
        end

        shim_roots = ShimRoots.for(root)
        text = Document::Text.new(event.source)
        collected = Index::Collector.collect(path, text, tree, @workspace.crystal_version)
        file = Index::Generated.merge(collected, event.sites, @workspace, @shims,
          Index::LoadedFiles.new(event.files.to_set, shim_roots))
        @generated[event.target] = file
        @workspace.update(file)
        @workspace.expand(event.target, event.expansions)
        @caches.invalidate
        sites = @sites[path] = Hash(Int32, Index::MacroSite).new
        event.sites.each { |site| sites[site.line] = site }
        @compiled[event.target] = event.files.to_set
        @methods.compiled(Resolve::Compiled.new(@compiled, shim_roots))
        elapsed = event.elapsed.total_milliseconds.round
        case event.target
        in .main?
          @status = MacrosDone.new(file.defs.size, elapsed, event.excluded.note(root))
          notify
        in .spec?, .loose?
          note = event.excluded.note(root)
          notify_target(event.target, Stage::Done, note, file.defs.size)
        end
        open_paths.each { |open_path| want_loose(open_path, root, semantic) }
      end

      def failed(event : Index::MacrosFailed) : Nil
        broken(event.target, event.reason)
      end

      def unavailable(event : Index::MacrosUnavailable) : Nil
        case event.target
        in .main?
          @status = MacrosOff.new(event.reason)
          notify
        in .spec?, .loose?
          notify_target(event.target, Stage::Unavailable, event.reason, 0)
        end
      end

      def finished(root : String, semantic : String?, target : Index::MacroTarget) : Nil
        @runner.finished(root, semantic, target)
      end

      def hint : String
        case (status = @status)
        in MacrosPending         then "; macros are still expanding"
        in MacrosStale           then "; macros could not be expanded (#{status.reason})"
        in MacrosOff, MacrosDone then ""
        end
      end

      def site_of(entry : Index::Entry) : Index::MacroSite?
        sites = @sites[entry.path]?
        return unless sites

        sites[entry.name_span.start_line.to_i + 1]?
      end

      def provenance(entry : Index::Entry, root : String) : String?
        site_of(entry).try { |site| "# #{site.provenance(root)}" }
      end

      private def want_loose(path : String, root : String, semantic : String?) : Nil
        return unless @compiled.has_key?(Index::MacroTarget::Main)
        return unless ProjectFiles.include?(path, root)
        return if path.starts_with?(File.join(root, "spec") + "/")
        return if compiled_files.includes?(path) || @loose.includes?(path)

        @loose << path
        @runner.loose(@loose.to_a)
        @runner.start(root, semantic, :loose)
      end

      private def want_spec(path : String, root : String, semantic : String?) : Nil
        return if @spec_wanted || !path.starts_with?(File.join(root, "spec") + "/")

        @spec_wanted = true
        @runner.start(root, semantic, :spec) if @indexed
      end

      private def broken(target : Index::MacroTarget, reason : String) : Nil
        case target
        in .main?
          @status = MacrosStale.new(reason, generated_defs)
          notify
        in .spec?, .loose?
          defs = @generated[target]?.try(&.defs.size) || 0
          notify_target(target, Stage::Stale, reason, defs)
        end
      end

      private def generated_defs : Int32
        @generated[Index::MacroTarget::Main]?.try(&.defs.size) || 0
      end

      private def notify : Nil
        @transport.send(Protocol::Encoder.notification(Notice::Macros.method, @status.payload))
      end

      private def notify_target(
        target : Index::MacroTarget,
        stage : Stage,
        reason : String?,
        defs : Int32,
      ) : Nil
        payload = MacrosPayload.new(stage, defs, 0.0, reason, target)
        @transport.send(Protocol::Encoder.notification(Notice::Macros.method, payload))
      end
    end
  end
end
