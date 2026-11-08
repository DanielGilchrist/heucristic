require "json"
require "../src/heucristic/index/loader"
require "../src/heucristic/index/shims"
require "../src/heucristic/index/workspace"
require "../src/heucristic/crystal_env"
require "../src/heucristic/server/shim_roots"
require "./score/corpus"
require "./score/expansion"
require "./score/options"
require "./score/scan"
require "./score/sweep"

module Score
  extend self

  def run(args : Array(String)) : Int32
    options = Options.parse(args)
    return options.report if options.is_a?(Invalid)

    stdlib = Heucristic::CrystalEnv.source_paths(options.root)
    if stdlib.is_a?(Heucristic::CrystalEnv::Unavailable)
      STDERR.puts stdlib.reason
      return 1
    end

    version = Heucristic::CrystalEnv.version
    if version.is_a?(Heucristic::CrystalVersion::Unknown)
      STDERR.puts version.reason
      return 1
    end

    events = Channel(Heucristic::Index::Event).new(64)
    shim_roots = Heucristic::Server::ShimRoots.for(options.root)
    Heucristic::Fibers.detach(:indexer) do
      Heucristic::Index::Loader.load([options.root] + stdlib, shim_roots, version, events)
    end
    finished = loop do
      event = events.receive
      break event if event.is_a?(Heucristic::Index::Finished)
    end

    workspace = Heucristic::Index::Workspace.new
    workspace.crystal_version = version
    workspace.replace_all(finished.files)
    shims = Heucristic::Index::Shims.new
    shims.replace_all(finished.shims)
    expansion = Expansion.new(options.root, events, workspace, shims, options.defines)
    targets = options.macros ? expansion.all : nil
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, shim_roots)) if targets
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    corpus = Corpus.new(
      options.root, workspace, finished.sites, types, methods, receiver, shim_roots,
      targets.try { |found| found.each_value.reduce(Set(String).new) { |all, files| all | files } },
      targets.try(&.[Heucristic::Index::MacroTarget::Main]?),
      expansion.origins,
    )

    case options.mode
    in .check? then Sweep.new(corpus, options).run
    in .scan?  then Scan.new(corpus, options).run
    end
  end
end

exit Score.run(ARGV)
