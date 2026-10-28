require "../../src/heucristic/index/collector"
require "../../src/heucristic/index/generated"
require "../../src/heucristic/index/shims"
require "../../src/heucristic/index/workspace"
require "../../src/heucristic/resolve/types"
require "../../src/heucristic/resolve/methods"
require "../../src/heucristic/resolve/receiver"
require "../../src/heucristic/server/macros"
require "../../src/heucristic/syntax/uses"

module ShimsCheck
  module Verify
    extend self

    PROBES = File.expand_path("#{__DIR__}/probes.cr")

    UNPROBEABLE = {
      "Object#==(other)" => "abstract; Reference and Value override it for every concrete type",
    }

    CHECKER = <<-'CR'

      def __heucristic_check(line : Int32, actual : T.class, expected : U.class) : Nil forall T, U
        {% if !(T <= U) %}
          puts "#{line}\tmismatch\t#{T}\t#{U}"
        {% elsif U.union_types.any? { |want| !T.union_types.any? { |have| have <= want } } %}
          puts "#{line}\twider\t#{T}\t#{U}"
        {% else %}
          puts "#{line}\tok"
        {% end %}
      end

      CR

    record Probe,
      line : Int32,
      source : String,
      expected : String,
      start : Crystal::Location,
      finish : Crystal::Location

    record Unresolved, line : Int32, source : String, reason : String

    record Mismatch,
      line : Int32,
      source : String,
      compiler : String,
      heucristic : String,
      wider : Bool

    record Resolver,
      receiver : Heucristic::Resolve::Receiver,
      methods : Heucristic::Resolve::Methods

    def run(
      files : Array(Heucristic::Index::File),
      shims : Heucristic::Index::Shims,
      applicable : Set(String),
      shim_roots : Array(String),
    ) : Int32
      source = File.read(PROBES)
      tree = Heucristic::Syntax.parse(source, PROBES)
      if tree.is_a?(Heucristic::Syntax::Broken)
        puts "probes do not parse: #{tree.message}"
        return 1
      end

      resolver = resolver_for(files, shims, source, tree, shim_roots)
      sites = Heucristic::Syntax::Uses.in(tree, PROBES).calls
      covered = covered_shims(sites, resolver, shims)
      probes = Array(Probe).new
      unresolved = Array(Unresolved).new
      collect_probes(sites, resolver.receiver, probes, unresolved)
      mismatches = compile(source, probes)
      return 1 unless mismatches

      uncovered = uncovered_shims(shims, applicable, covered)
      verified = probes.size - mismatches.size
      puts "probes: #{probes.size + unresolved.size}, verified by the compiler: #{verified}"
      contradicted = mismatches.reject(&.wider).map { |found| describe(found) }
      report("mismatches (the compiler's type is not within heucristic's)", contradicted)
      widened = mismatches.select(&.wider).map { |found| describe(found) }
      report("widened (heucristic adds union members the compiler never produces)", widened)
      report("probes heucristic cannot type", unresolved.map do |missing|
        "#{missing.line}: #{missing.source}  #{missing.reason}"
      end)
      report("shims no probe exercises", uncovered)
      unreachable = UNPROBEABLE.map { |identity, reason| "#{identity}: #{reason}" }
      report("shims no call can reach", unreachable)
      mismatches.empty? && unresolved.empty? && uncovered.empty? ? 0 : 1
    end

    private def resolver_for(
      files : Array(Heucristic::Index::File),
      shims : Heucristic::Index::Shims,
      source : String,
      tree : Crystal::ASTNode,
      shim_roots : Array(String),
    ) : Resolver
      workspace = Heucristic::Index::Workspace.new
      workspace.replace_all(files)
      text = Heucristic::Document::Text.new(source)
      workspace.update(Heucristic::Index::Collector.collect(PROBES, text, tree))
      types = Heucristic::Resolve::Types.new(workspace)
      methods = Heucristic::Resolve::Methods.new(workspace, types)
      loaded = expand(workspace, shims)
      if loaded
        targets = {Heucristic::Index::MacroTarget::Loose => loaded}
        methods.compiled(Heucristic::Resolve::Compiled.new(targets, shim_roots))
      end
      Resolver.new(Heucristic::Resolve::Receiver.new(workspace, shims, types, methods), methods)
    end

    private def expand(
      workspace : Heucristic::Index::Workspace,
      shims : Heucristic::Index::Shims,
    ) : Set(String)?
      events = Channel(Heucristic::Index::Event).new(64)
      macros = Heucristic::Server::Macros.new(events)
      macros.loose([PROBES])
      macros.start(Dir.current, nil, :loose)
      result = loop do
        event = events.receive
        break event unless event.is_a?(Heucristic::Index::MacrosStarted)
      end
      return report_expansion(result) unless result.is_a?(Heucristic::Index::MacrosExpanded)

      path = Heucristic::Index::MacroTarget::Loose.generated_path
      generated = Heucristic::Syntax.parse(result.source, path)
      return if generated.is_a?(Heucristic::Syntax::Broken)

      text = Heucristic::Document::Text.new(result.source)
      collected = Heucristic::Index::Collector.collect(path, text, generated)
      merged = Heucristic::Index::Generated.merge(collected, result.sites, workspace, shims)
      workspace.update(merged)
      workspace.expand(Heucristic::Index::MacroTarget::Loose, result.expansions)
      result.files.to_set
    end

    private def report_expansion(result : Heucristic::Index::Event) : Nil
      puts "macros: #{result.class.name.split("::").last}; platform-specific stdlib stays ambiguous"
    end

    private def covered_shims(
      sites : Array(Heucristic::Syntax::Uses::CallSite),
      resolver : Resolver,
      shims : Heucristic::Index::Shims,
    ) : Set(String)
      covered = Set(String).new
      probed = Set(UInt64).new
      sites.each do |site|
        call = site.call
        next unless call.obj.nil? && call.name == "probe" && call.args.size == 1

        probed << call.args[0].object_id
      end
      sites.each do |site|
        next unless probed.includes?(site.call.object_id)

        target = resolver.receiver.of_call(site.call, site.context)
        next if target.is_a?(Heucristic::Resolve::Unknown)

        shape = resolver.receiver.shape_of(site.call, site.context)
        reached = resolver.methods.dispatch(target, shape).dup
        resolver.methods.concrete_subclasses(target, shape.caller_path).each do |below|
          reached.concat(resolver.methods.lookup(below, shape))
        end
        reached.each do |entry|
          shims.find(entry).try { |shim| covered << shim.entry.identity }
        end
      end
      covered
    end

    private def collect_probes(
      sites : Array(Heucristic::Syntax::Uses::CallSite),
      receiver : Heucristic::Resolve::Receiver,
      probes : Array(Probe),
      unresolved : Array(Unresolved),
    ) : Nil
      by_node = Hash(UInt64, Heucristic::Syntax::Uses::CallSite).new
      sites.each { |site| by_node[site.call.object_id] = site }
      sites.each do |site|
        call = site.call
        next unless call.obj.nil? && call.name == "probe" && call.args.size == 1

        line = call.location.try(&.line_number) || 0
        argument = call.args[0]
        inner = by_node[argument.object_id]?
        next unresolved << Unresolved.new(line, argument.to_s, "not a call") unless inner

        typed = receiver.result_of(inner.call, inner.context)
        text = typed.to_s
        start = call.location
        finish = call.end_location
        if typed.is_a?(Heucristic::Resolve::Unknown) || text.includes?("unknown")
          unresolved << Unresolved.new(line, argument.to_s, text)
        elsif start && finish
          probes << Probe.new(line, argument.to_s, text, start, finish)
        end
      end
    end

    private def uncovered_shims(
      shims : Heucristic::Index::Shims,
      applicable : Set(String),
      covered : Set(String),
    ) : Array(String)
      uncovered = Array(String).new
      shims.each do |shim|
        identity = shim.entry.identity
        next unless applicable.includes?(identity)
        next if covered.includes?(identity) || UNPROBEABLE.has_key?(identity)

        uncovered << "#{identity}  (#{File.basename(shim.entry.path)})"
      end
      uncovered
    end

    private def compile(source : String, probes : Array(Probe)) : Array(Mismatch)?
      directory = File.join(Path.home.to_s, ".cache", "heucristic", "shims-verify")
      Dir.mkdir_p(directory)
      path = File.join(directory, "verify.cr")
      File.write(path, CHECKER + replaced(source, probes))
      output = IO::Memory.new
      errors = IO::Memory.new
      arguments = ["run", "--no-color", path]
      status = Process.run("crystal", arguments, output: output, error: errors, input: :close)
      unless status.success?
        puts "the compiler rejected the verification program:"
        puts errors.to_s.lines.reject(&.includes?("warning")).first(20).join("\n")
        return
      end

      mismatches(output.to_s, probes)
    end

    private def mismatches(output : String, probes : Array(Probe)) : Array(Mismatch)
      by_line = probes.to_h { |probe| {probe.line, probe} }
      found = Array(Mismatch).new
      output.each_line do |line|
        fields = line.split('\t')
        kind = fields[1]?
        next unless kind == "mismatch" || kind == "wider"

        probe = by_line[fields[0].to_i]?
        next unless probe

        found << Mismatch.new(probe.line, probe.source, fields[2], fields[3], kind == "wider")
      end
      found
    end

    private def replaced(source : String, probes : Array(Probe)) : String
      lines = source.lines(chomp: false)
      ordered = probes.sort_by { |probe| {-probe.start.line_number, -probe.start.column_number} }
      ordered.each do |probe|
        check = "__heucristic_check(#{probe.line}, typeof(#{probe.source}), #{probe.expected})"
        first = probe.start.line_number - 1
        last = probe.finish.line_number - 1
        head = lines[first][0, probe.start.column_number - 1]
        tail = lines[last][probe.finish.column_number..]? || "\n"
        lines[first..last] = [head + check + tail]
      end
      lines.join
    end

    private def describe(found : Mismatch) : String
      "#{found.line}: #{found.source}  compiler: #{found.compiler}  heucristic: #{found.heucristic}"
    end

    private def report(title : String, lines : Array(String)) : Nil
      puts "#{title}: #{lines.size}"
      lines.each { |line| puts "  #{line}" }
    end
  end
end
