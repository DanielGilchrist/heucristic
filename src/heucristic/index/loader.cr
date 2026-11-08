require "../fibers"
require "../disk"
require "../log"
require "../crystal_version"
require "../syntax"
require "./collector"
require "./indexed"
require "./sites"
require "./event"

module Heucristic
  module Index
    module Loader
      extend self

      REPORT_EVERY = 32

      def load(
        roots : Array(String),
        shim_roots : Array(String),
        version : CrystalVersion::Detected,
        events : Channel(Event),
      ) : Nil
        started = Time.instant
        generated, shim_paths = glob(shim_roots).partition { |path| generated?(path) }
        shim_set = shim_paths.to_set
        paths = glob(roots).reject { |path| shim_set.includes?(path) } + shim_paths + generated
        events.send(Started.new(paths.size))

        results = Channel(Indexed?).new(paths.size + 1)
        workers = Math.min(Fibers::WORKER_THREADS, Math.max(paths.size, 1))
        project = roots.first?
        Fibers.detach(:indexer) do
          Fibers.parallel(:indexer, workers) do |worker|
            index_slice(paths, worker, workers, results, project, version)
          end
        end

        files = Array(File).new(paths.size)
        shims_by_path = Hash(String, File).new(initial_capacity: shim_paths.size)
        sites = Array(Sites).new
        paths.size.times do |done|
          indexed = results.receive
          if indexed
            file = indexed.file
            if shim_set.includes?(file.path)
              shims_by_path[file.path] = file
            else
              files << file
            end
            indexed.sites.try { |found| sites << found }
          end
          events.send(Advanced.new(done + 1, paths.size)) if (done + 1) % REPORT_EVERY == 0
        end
        shims = shim_paths.compact_map { |path| shims_by_path[path]? }
        events.send(Finished.new(files, shims, sites, Time.instant - started))
      end

      def glob(roots : Array(String)) : Array(String)
        roots.flat_map { |root| Dir.glob(::File.join(root, "**", "*.cr")) }.uniq!
      end

      def generated?(path : String) : Bool
        path.includes?("/generated/")
      end

      def index_path(
        path : String,
        project : String?,
        version : CrystalVersion::Detected,
      ) : Indexed?
        source = Disk.read(path)
        if source.is_a?(Disk::Unreadable)
          Log.info("skipping #{path}: #{source.reason}")
          return
        end

        index_source(path, source, version, project)
      end

      def index_source(
        path : String,
        source : String,
        version : CrystalVersion::Detected,
        project : String? = nil,
      ) : Indexed?
        tree = Syntax.parse(source, path)
        return if tree.is_a?(Syntax::Broken)

        text = Document::Text.new(source)
        file = Collector.collect(path, text, tree, version)
        sites = project && path.starts_with?(project) ? Sites.of(path, text, tree, version) : nil
        Indexed.new(file, sites)
      end

      private def index_slice(
        paths : Array(String),
        worker : Int32,
        workers : Int32,
        results : Channel(Indexed?),
        project : String?,
        version : CrystalVersion::Detected,
      ) : Nil
        index = worker
        while index < paths.size
          results.send(index_path(paths[index], project, version))
          index += workers
        end
      end
    end
  end
end
