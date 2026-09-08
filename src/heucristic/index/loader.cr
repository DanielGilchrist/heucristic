require "../fibers"
require "../disk"
require "../log"
require "../syntax/parse"
require "./collector"
require "./event"

module Heucristic
  module Index
    module Loader
      extend self

      REPORT_EVERY = 32

      def load(roots : Array(String), events : Channel(Event)) : Nil
        started = Time.instant
        paths = roots.flat_map { |root| Dir.glob(::File.join(root, "**", "*.cr")) }.uniq!
        events.send(Started.new(paths.size))

        results = Channel(File?).new(paths.size + 1)
        workers = Math.min(Fibers::WORKER_THREADS, Math.max(paths.size, 1))
        Fibers.detach(:indexer) do
          Fibers.parallel(:indexer, workers) do |worker|
            index_slice(paths, worker, workers, results)
          end
        end

        files = Array(File).new(paths.size)
        paths.size.times do |done|
          file = results.receive
          files << file if file
          events.send(Advanced.new(done + 1, paths.size)) if (done + 1) % REPORT_EVERY == 0
        end
        events.send(Finished.new(files, Time.instant - started))
      end

      def index_path(path : String) : File?
        source = Disk.read(path)
        if source.is_a?(Disk::Unreadable)
          Log.info("skipping #{path}: #{source.reason}")
          return
        end

        index_source(path, source)
      end

      def index_source(path : String, source : String) : File?
        tree = Syntax.parse(source, path)
        return if tree.is_a?(Syntax::Broken)

        Collector.collect(path, Document::Text.new(source), tree)
      end

      private def index_slice(
        paths : Array(String),
        worker : Int32,
        workers : Int32,
        results : Channel(File?),
      ) : Nil
        index = worker
        while index < paths.size
          results.send(index_path(paths[index]))
          index += workers
        end
      end
    end
  end
end
