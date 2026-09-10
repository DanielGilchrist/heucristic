require "json"
require "../src/heucristic/index/loader"
require "../src/heucristic/index/shims"
require "../src/heucristic/index/workspace"
require "../src/heucristic/index/collector"
require "../src/heucristic/crystal_env"
require "../src/heucristic/server/shim_roots"
require "../src/heucristic/syntax/calls"
require "../src/heucristic/resolve/types"
require "../src/heucristic/resolve/methods"
require "../src/heucristic/resolve/receiver"

module Score
  extend self

  MACROS  = {"record", "require", "raise", "puts", "p", "pp"}
  SKIPPED = Heucristic::Index::Collector::ACCESSORS + MACROS

  record Outcome,
    path : String,
    line : Int32,
    column : Int32,
    name : String,
    result : Heucristic::Resolve::Resolution,
    targets : Array(String)

  def run(args : Array(String)) : Int32
    root = File.expand_path(args[0]? || Dir.current)
    verify = (args.index("--verify").try { |index| args[index + 1]?.try(&.to_i?) }) || 0
    main = args.index("--main").try { |index| args[index + 1]? }

    stdlib = Heucristic::CrystalEnv.source_paths(root)
    if stdlib.is_a?(Heucristic::CrystalEnv::Unavailable)
      STDERR.puts stdlib.reason
      return 1
    end

    events = Channel(Heucristic::Index::Event).new(64)
    shim_roots = Heucristic::Server::ShimRoots.for(root)
    spawn { Heucristic::Index::Loader.load([root] + stdlib, shim_roots, events) }
    finished = loop do
      event = events.receive
      break event if event.is_a?(Heucristic::Index::Finished)
    end

    workspace = Heucristic::Index::Workspace.new
    workspace.replace_all(finished.files)
    shims = Heucristic::Index::Shims.new
    shims.replace_all(finished.shims)
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)

    at = args.index("--at").try { |index| args[index + 1]? }
    outcomes = Array(Outcome).new
    elapsed = Time.measure do
      Dir.glob(File.join(root, "src", "**", "*.cr")).sort.each do |path|
        source = File.read(path)
        tree = Heucristic::Syntax.parse(source, path)
        next unless tree.is_a?(Crystal::ASTNode)

        Heucristic::Syntax::Calls.in(tree, path).each do |site|
          call = site.call
          next if SKIPPED.includes?(call.name) && call.obj.nil?
          location = call.name_location
          next unless location

          result = receiver.result_of(call, site.context)
          targets = targets_of(call, site.context, receiver, methods)
          if at == "#{path.sub(root + "/", "")}:#{location.line_number}:#{location.column_number}"
            puts "#{call.name} at #{at}: #{result}"
            puts "  receiver: #{receiver.of_call(call, site.context)}"
            chain = site.context.ancestors.map(&.class.name.sub("Crystal::", ""))
            puts "  ancestors: #{chain.join(" > ")}"
            puts "  def: #{site.context.def_node.try(&.name)}, blocks: #{site.context.blocks.size}"
          end
          outcomes << Outcome.new(
            path, location.line_number, location.column_number, call.name, result, targets
          )
        end
      end
    end

    report(outcomes, elapsed, root)
    verify_sample(outcomes, verify, main, root) if verify > 0 && main
    0
  end

  private def targets_of(
    call : Crystal::Call,
    context : Heucristic::Syntax::Context,
    receiver : Heucristic::Resolve::Receiver,
    methods : Heucristic::Resolve::Methods,
  ) : Array(String)
    typed = receiver.of_call(call, context)
    return Array(String).new if typed.is_a?(Heucristic::Resolve::Unknown)

    methods.lookup(typed, receiver.shape_of(call, context)).map do |entry|
      "#{entry.path}:#{entry.name_span.start_line + 1}"
    end
  end

  private def report(outcomes : Array(Outcome), elapsed : Time::Span, root : String) : Nil
    resolved, unknown = outcomes.partition(&.result.is_a?(Heucristic::Resolve::Resolved))
    puts "#{outcomes.size} calls in #{root}/src scored in #{elapsed.total_milliseconds.round}ms"
    puts "resolved: #{resolved.size} (#{percent(resolved.size, outcomes.size)})"
    puts "unknown:  #{unknown.size} (#{percent(unknown.size, outcomes.size)})"
    puts

    by_reason = unknown.group_by do |outcome|
      outcome.result.as?(Heucristic::Resolve::Unknown).try(&.reason)
    end
    by_reason.to_a.sort_by { |_, group| -group.size }.each do |reason, group|
      share = percent(group.size, outcomes.size)
      puts "  #{reason.to_s.ljust(16)} #{group.size.to_s.rjust(5)}  #{share}"
      details = group.group_by(&.result.to_s).to_a.sort_by { |_, sites| -sites.size }
      details.first(5).each do |detail, sites|
        first = sites[0]
        where = "#{first.path.sub(root + "/", "")}:#{first.line}:#{first.column}"
        puts "      #{sites.size.to_s.rjust(4)}x #{detail}  e.g. #{where}"
      end
    end
  end

  private def verify_sample(
    outcomes : Array(Outcome),
    count : Int32,
    main : String,
    root : String,
  ) : Nil
    resolved = outcomes.select(&.result.is_a?(Heucristic::Resolve::Resolved))
    sample = resolved.sample(Math.min(count, resolved.size), Random.new(7))
    puts
    puts "verifying #{sample.size} resolved calls against `crystal tool implementations`"
    agree = 0
    disagree = 0
    unseen = 0
    sample.each do |outcome|
      cursor = "#{outcome.path}:#{outcome.line}:#{outcome.column}"
      output = IO::Memory.new
      status = Process.run(
        "crystal",
        {
          "tool", "implementations", "--no-color", "-f", "json", "-c", cursor,
          File.join(root, main),
        },
        output: output, error: Process::Redirect::Close
      )
      unless status.success?
        puts "  compiler failed at #{cursor.sub(root + "/", "")}"
        next
      end
      compiler = JSON.parse(output.to_s)
      locations = compiler["implementations"]?.try(&.as_a?) || Array(JSON::Any).new
      theirs = locations.map { |impl| "#{impl["filename"]}:#{impl["line"]}" }
      where = cursor.sub(root + "/", "")
      if theirs.empty?
        unseen += 1
        puts "  ? #{where} #{outcome.name}: compiler reports no implementation"
      elsif same_targets?(theirs, outcome.targets)
        agree += 1
      elsif same_files?(theirs, outcome.targets)
        agree += 1
        puts "  ~ #{where} #{outcome.name}: same file, different line (macro-generated def)"
      else
        disagree += 1
        puts "  X #{where} #{outcome.name}"
        puts "      ours:     #{outcome.targets.map(&.sub(root + "/", "")).join(", ")}"
        puts "      compiler: #{theirs.map(&.sub(root + "/", "")).join(", ")}"
      end
    end
    puts "agree: #{agree}, disagree: #{disagree}, compiler saw no implementation: #{unseen}"
  end

  private def same_targets?(theirs : Array(String), ours : Array(String)) : Bool
    theirs.sort == ours.sort
  end

  private def same_files?(theirs : Array(String), ours : Array(String)) : Bool
    theirs.map(&.rpartition(':')[0]).sort! == ours.map(&.rpartition(':')[0]).sort!
  end

  private def percent(part : Int32, whole : Int32) : String
    whole.zero? ? "0%" : "#{(part * 100 // whole)}%"
  end
end

exit Score.run(ARGV)
