require "json"
require "../src/heucristic/index/loader"
require "../src/heucristic/index/shims"
require "../src/heucristic/index/workspace"
require "../src/heucristic/index/collector"
require "../src/heucristic/index/accessor"
require "../src/heucristic/crystal_env"
require "../src/heucristic/server/shim_roots"
require "../src/heucristic/server/macros"
require "../src/heucristic/index/generated"
require "../src/heucristic/document/text"
require "../src/heucristic/syntax/uses"
require "../src/heucristic/resolve/types"
require "../src/heucristic/resolve/methods"
require "../src/heucristic/resolve/receiver"
require "../src/heucristic/check/calls"
require "../src/heucristic/check/cases"
require "../src/heucristic/check/abstracts"
require "../src/heucristic/check/generics"
require "../src/heucristic/check/controls"
require "../src/heucristic/check/paths"
require "../src/heucristic/check/returns"
require "../src/heucristic/check/instance_vars"
require "../src/heucristic/check/settled"
require "./score/verifier"

module Score
  extend self

  STATEMENTS   = {"require", "raise", "puts", "p", "pp"}
  DECLARATIONS = {
    "record", "delegate", "def_equals", "def_hash", "def_equals_and_hash", "forward_missing_to",
    "def_clone",
  }
  SKIPPED = Heucristic::Index::Accessor.names + STATEMENTS.to_a + DECLARATIONS.to_a

  BUDGET_MS = 25.0
  ROUNDS    =    3

  record Timing, path : String, milliseconds : Float64

  record Outcome,
    path : String,
    line : Int32,
    column : Int32,
    name : String,
    result : Heucristic::Resolve::Resolution,
    targets : Array(Heucristic::Index::Def),
    interpolated : Bool

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
    origins = Hash(String, Heucristic::Index::MacroSite).new
    expand = !args.includes?("--no-macros")
    targets = expand ? expand_all(root, events, workspace, shims, origins) : nil
    compiled = targets.try do |found|
      found.each_value.reduce(Set(String).new) { |all, files| all | files }
    end
    main_files = targets.try(&.[Heucristic::Index::MacroTarget::Main]?)
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    methods.compiled(Heucristic::Resolve::Compiled.new(targets, shim_roots)) if targets
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    if args.includes?("--check")
      return check(root, workspace, finished.sites, types, methods, receiver, shim_roots, compiled)
    end

    at = args.index("--at").try { |index| args[index + 1]? }
    outcomes = Array(Outcome).new
    elapsed = Time.measure do
      if at
        inspect_line(
          at, root, workspace, finished.sites, types, methods, receiver, shim_roots, compiled
        )
      end
      scanned = at ? finished.sites.map(&.path) : Dir.glob(File.join(root, "src", "**", "*.cr"))
      scanned.sort.each do |path|
        next if at && !at.starts_with?(path.sub(root + "/", "") + ":")
        source = File.read(path)
        tree = Heucristic::Syntax.parse(source, path)
        next unless tree.is_a?(Crystal::ASTNode)

        Heucristic::Syntax::Uses.in(tree, path).calls.each do |site|
          call = site.call
          next if SKIPPED.includes?(call.name) && call.obj.nil?
          next if inside_macro_arguments?(site.context.ancestors)
          location = call.name_location
          next unless location

          result = receiver.result_of(call, site.context)
          implemented = targets_of(call, site.context, receiver)
          here = "#{path.sub(root + "/", "")}:#{location.line_number}"
          if at == here || at == "#{here}:#{location.column_number}"
            puts "#{call.name} at #{at}: #{result}"
            puts "  receiver: #{receiver.of_call(call, site.context)}"
            shape = receiver.shape_of(call, site.context)
            puts "  arguments: #{shape.arguments.join(", ")} precisions: #{shape.precisions}"
            typed = receiver.of_call(call, site.context)
            if typed.is_a?(Heucristic::Resolve::Resolved)
              methods.named_on(typed, call.name, site.context.path).each do |entry|
                rejected = methods.rejected_argument(entry, shape, any_member: true)
                verdict = if rejected
                            "rejects #{rejected.actual} for #{rejected.expected}"
                          else
                            "accepts"
                          end
                puts "  #{entry.signature}: #{verdict}"
              end
            end
            chain = site.context.ancestors.map(&.class.name.sub("Crystal::", ""))
            puts "  ancestors: #{chain.join(" > ")}"
            puts "  def: #{site.context.def_node.try(&.name)}, blocks: #{site.context.blocks.size}"
          end
          outcomes << Outcome.new(
            path, location.line_number, location.column_number, call.name, result, implemented,
            interpolated?(site.context.ancestors)
          )
        end
      end
    end

    report(outcomes, elapsed, root)
    if verify > 0 && main
      verify_sample(outcomes, verify, main, root, main_files, workspace, types, origins)
    end
    0
  end

  private def check(
    root : String,
    workspace : Heucristic::Index::Workspace,
    all : Array(Heucristic::Index::Sites),
    types : Heucristic::Resolve::Types,
    methods : Heucristic::Resolve::Methods,
    receiver : Heucristic::Resolve::Receiver,
    shim_roots : Array(String),
    compiled : Set(String)?,
  ) : Int32
    settled = Heucristic::Check::Settled.new(
      workspace,
      types,
      !compiled.nil?,
      Set(String).new,
      compiled || Set(String).new,
      root,
      shim_roots,
    )
    checks = Heucristic::Check::Calls.new(workspace, types, methods, receiver, settled)
    total = 0
    checked = 0
    calls = 0
    skips = Hash(Heucristic::Check::Skip, Int32).new(0)
    examples = Hash(Heucristic::Check::Skip, String).new
    unknown = Hash(String, Int32).new(0)
    unsettled = Hash(String, Int32).new(0)
    macro_calls = Hash(String, Int32).new(0)
    timings = Array(Timing).new
    uncompiled = Array(String).new
    only = ARGV.index("--only").try { |index| ARGV[index + 1]? }
    elapsed = Time.measure do
      all.sort_by(&.path).each do |sites|
        next if sites.path.starts_with?(File.join(root, "lib") + "/")
        next if only && !sites.path.ends_with?(only)
        next if shim_roots.any? { |shim_root| sites.path.starts_with?(shim_root + "/") }

        calls += sites.calls.size
        uncompiled << sites.path.sub(root + "/", "") if settled.uncompiled_file?(sites.path)
        findings = Array(Heucristic::Check::Finding).new
        spent = Time.measure do
          outcome = checks.run(sites)
          checked += outcome.checked
          outcome.skips.each { |skip, count| skips[skip] += count }
          outcome.examples.each { |skip, where| examples[skip] ||= where }
          outcome.unknown_receivers.each { |detail, count| unknown[detail] += count }
          outcome.unsettled_types.each { |type, count| unsettled[type] += count }
          outcome.macro_calls.each { |name, count| macro_calls[name] += count }
          findings = outcome.findings
          Heucristic::Check::Cases.new(workspace, types, receiver, settled).run(sites, findings)
          Heucristic::Check::Abstracts.new(workspace, methods, settled).run(sites.path, findings)
          Heucristic::Check::Generics.new(workspace, types, settled, root).run(sites, findings)
          Heucristic::Check::Controls.new(workspace).run(sites, findings)
          Heucristic::Check::Paths.new(workspace, types, settled).run(sites, findings)
          Heucristic::Check::Returns.new(types, methods, receiver, settled).run(sites, findings)
          Heucristic::Check::InstanceVars.new(workspace, types, methods, receiver, settled)
            .run(sites, findings)
        end
        timings << Timing.new(sites.path.sub(root + "/", ""), spent.total_milliseconds)
        findings.sort_by! { |finding| {finding.span.start_line, finding.span.start_character} }
        findings.each do |finding|
          total += 1
          where = "#{sites.path.sub(root + "/", "")}:#{finding.span.start_line + 1}"
          puts "#{where}: #{finding.rule.code}: #{finding.message}"
        end
      end
    end
    puts "#{total} findings; #{checked} of #{calls} calls in #{all.size} files were checkable " \
         "(#{elapsed.total_milliseconds.round}ms cold sweep)"
    explain_skips(skips, examples, unknown, unsettled, macro_calls, root) if ARGV.includes?("--why")
    if ARGV.includes?("--why") && !uncompiled.empty?
      puts "files no target compiled (#{uncompiled.size}):"
      uncompiled.first(12).each { |path| puts "  #{path}" }
    end
    timings.clear
    all.each do |sites|
      next if sites.path.starts_with?(File.join(root, "lib") + "/")
      next if only && !sites.path.ends_with?(only)

      spent = Time.measure { ROUNDS.times { checks.run(sites) } }
      timings << Timing.new(sites.path.sub(root + "/", ""), spent.total_milliseconds / ROUNDS)
    end
    slowest = timings.sort_by { |timing| -timing.milliseconds }.first(3)
    slowest.each { |timing| puts "  #{timing.milliseconds.round(1)}ms #{timing.path}" }
    over = slowest.first?.try { |timing| timing.milliseconds > BUDGET_MS } || false
    puts "budget: #{BUDGET_MS}ms per warm file check #{over ? "EXCEEDED" : "met"}"
    return 3 if over

    total.zero? ? 0 : 2
  end

  private def explain_skips(
    skips : Hash(Heucristic::Check::Skip, Int32),
    examples : Hash(Heucristic::Check::Skip, String),
    unknown : Hash(String, Int32),
    unsettled : Hash(String, Int32),
    macro_calls : Hash(String, Int32),
    root : String,
  ) : Nil
    puts
    puts "not checkable because:"
    skips.to_a.sort_by { |_, count| -count }.each do |skip, count|
      where = examples[skip]?.try(&.sub(root + "/", "")) || ""
      puts "  #{count.to_s.rjust(6)}  #{skip.label.ljust(22)} e.g. #{where}"
    end
    top("receivers the resolver could not type:", unknown)
    top("receiver types that are not settled:", unsettled)
    top("macro invocations skipped:", macro_calls)
  end

  private def top(title : String, counts : Hash(String, Int32)) : Nil
    return if counts.empty?

    puts
    puts title
    counts.to_a.sort_by { |_, count| -count }.first(12).each do |detail, count|
      puts "  #{count.to_s.rjust(6)}  #{detail}"
    end
  end

  private def inspect_line(
    at : String,
    root : String,
    workspace : Heucristic::Index::Workspace,
    all : Array(Heucristic::Index::Sites),
    types : Heucristic::Resolve::Types,
    methods : Heucristic::Resolve::Methods,
    receiver : Heucristic::Resolve::Receiver,
    shim_roots : Array(String),
    compiled : Set(String)?,
  ) : Nil
    parts = at.split(':')
    file = parts[0]
    line = parts[1]? || "0"
    sites = all.find { |candidate| candidate.path == File.join(root, file) }
    return puts "no indexed sites for #{file}" unless sites

    settled = Heucristic::Check::Settled.new(
      workspace,
      types,
      !compiled.nil?,
      Set(String).new,
      compiled || Set(String).new,
      root,
      shim_roots,
    )
    calls = Heucristic::Check::Calls.new(workspace, types, methods, receiver, settled)
    outcome = calls.run(sites)
    findings = outcome.findings
    Heucristic::Check::Returns.new(types, methods, receiver, settled).run(sites, findings)
    findings.each do |finding|
      near = (finding.span.start_line.to_i64 + 1 - line.to_i64).abs <= 40
      next unless near

      puts "check: #{finding.rule.code} #{finding.message.lines.first?}"
      puts "check:   spans lines #{finding.span.start_line + 1}-#{finding.span.end_line + 1}"
    end
    on_line = sites.calls.count { |site| site.call.name_location.try(&.line_number) == line.to_i }
    puts "check: #{on_line} calls on the line"
  end

  private def defines_from(args : Array(String)) : Array(String)
    found = Array(String).new
    args.each_with_index do |argument, index|
      found << args[index + 1] if argument == "--define" && args[index + 1]?
    end
    found
  end

  private def targets_of(
    call : Crystal::Call,
    context : Heucristic::Syntax::Context,
    receiver : Heucristic::Resolve::Receiver,
  ) : Array(Heucristic::Index::Def)
    typed = receiver.of_call(call, context)
    return Array(Heucristic::Index::Def).new if typed.is_a?(Heucristic::Resolve::Unknown)

    found = if call.obj.nil? && Heucristic::Syntax::WellKnown::Super.named?(call.name)
              receiver.super_targets(call, context)
            else
              receiver.implementations(typed, receiver.shape_of(call, context))
            end
    found
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
    main_files : Set(String)?,
    workspace : Heucristic::Index::Workspace,
    types : Heucristic::Resolve::Types,
    origins : Hash(String, Heucristic::Index::MacroSite),
  ) : Nil
    resolved = outcomes.select(&.result.is_a?(Heucristic::Resolve::Resolved))
    verifiable = resolved.reject(&.interpolated)
    only = ARGV.index("--only").try { |index| ARGV[index + 1]? }
    sample = if only
               verifiable.select { |outcome| at(outcome).ends_with?(only) }
             else
               verifiable.sample(Math.min(count, verifiable.size), Random.new(7))
             end
    puts
    puts "verifying #{sample.size} resolved calls against `crystal tool implementations`"
    left_out = resolved.size - verifiable.size
    puts "(#{left_out} resolved calls inside string interpolation are not verified: " \
         "the compiler tool answers for the interpolation, not the call)"
    verifier = Verifier.new(root, main, workspace, types, origins)
    tally = Hash(Verifier::Kind, Int32).new(0)
    sample.each do |outcome|
      ours = in_target(outcome.targets, main_files, root)
      probe = Verifier::Probe.new(outcome.path, outcome.line, outcome.column, outcome.result.to_s)
      where = "#{outcome.path}:#{outcome.line}:#{outcome.column}".sub(root + "/", "")
      verdict = verifier.judge(probe, ours)
      unless verdict
        puts "  compiler failed at #{where}"
        next
      end

      tally[verdict.kind] += 1
      next if verdict.kind.agree?

      puts "  #{marker(verdict.kind)} #{where} #{outcome.name}: #{verdict.message}"
    end
    Verifier::Kind.each do |kind|
      puts "#{kind.to_s.underscore.tr("_", " ")}: #{tally[kind]}"
    end
    puts "not verified inside string interpolation: #{left_out}"
  end

  private def at(outcome : Outcome) : String
    "#{outcome.path}:#{outcome.line}:#{outcome.column}"
  end

  private def marker(kind : Verifier::Kind) : String
    case kind
    in .agree?            then "="
    in .over_approximate? then "+"
    in .unverified?       then "?"
    in .disagree?         then "X"
    in .unseen?           then "-"
    end
  end

  private def interpolated?(ancestors : Array(Crystal::ASTNode)) : Bool
    ancestors.any?(Crystal::StringInterpolation)
  end

  private def inside_macro_arguments?(ancestors : Array(Crystal::ASTNode)) : Bool
    ancestors.each_with_index.any? do |node, index|
      next false unless node.is_a?(Crystal::Call) && node.obj.nil? && declaration?(node.name)

      block = node.block
      block.nil? || !ancestors[index + 1]?.try(&.same?(block))
    end
  end

  private def declaration?(name : String) : Bool
    DECLARATIONS.includes?(name) || !Heucristic::Index::Accessor.from_name(name).nil?
  end

  private def expand_all(
    root : String,
    events : Channel(Heucristic::Index::Event),
    workspace : Heucristic::Index::Workspace,
    shims : Heucristic::Index::Shims,
    origins : Hash(String, Heucristic::Index::MacroSite),
  ) : Hash(Heucristic::Index::MacroTarget, Set(String))?
    targets = Hash(Heucristic::Index::MacroTarget, Set(String)).new
    compiled = expand_macros(root, events, workspace, shims, origins, :main)
    return unless compiled
    targets[Heucristic::Index::MacroTarget::Main] = compiled
    if Dir.exists?(File.join(root, "spec"))
      from_specs = expand_macros(root, events, workspace, shims, origins, :spec)
      targets[Heucristic::Index::MacroTarget::Spec] = from_specs if from_specs
    end

    loose = Array(String).new
    workspace.each_file do |file|
      path = file.path
      next unless path.starts_with?(root + "/")
      next if path.starts_with?(File.join(root, "lib") + "/")
      next if path.starts_with?(File.join(root, "spec") + "/")
      next if Heucristic::Index::MacroTarget.generated?(path)
      next if targets.each_value.any?(&.includes?(path))

      loose << path
    end
    return targets if loose.empty?

    from_loose = expand_macros(root, events, workspace, shims, origins, :loose, loose)
    targets[Heucristic::Index::MacroTarget::Loose] = from_loose if from_loose
    targets
  end

  private def expand_macros(
    root : String,
    events : Channel(Heucristic::Index::Event),
    workspace : Heucristic::Index::Workspace,
    shims : Heucristic::Index::Shims,
    origins : Hash(String, Heucristic::Index::MacroSite),
    target : Heucristic::Index::MacroTarget,
    loose : Array(String) = Array(String).new,
  ) : Set(String)?
    macros = Heucristic::Server::Macros.new(events)
    macros.loose(loose)
    macros.defines(defines_from(ARGV))
    macros.start(root, nil, target)
    result = loop do
      event = events.receive
      break event unless event.is_a?(Heucristic::Index::MacrosStarted)
    end
    case result
    in Heucristic::Index::MacrosExpanded
      path = target.generated_path
      tree = Heucristic::Syntax.parse(result.source, path)
      if tree.is_a?(Heucristic::Syntax::Broken)
        puts "macros (#{target.wire}): generated source does not parse: #{tree.message}"
        return
      end
      text = Heucristic::Document::Text.new(result.source)
      collected = Heucristic::Index::Collector.collect(path, text, tree)
      loaded = Heucristic::Index::LoadedFiles.new(
        result.files.to_set, Heucristic::Server::ShimRoots.for(root)
      )
      file = Heucristic::Index::Generated.merge(collected, result.sites, workspace, shims, loaded)
      workspace.update(file)
      workspace.expand(target, result.expansions)
      result.sites.each { |site| origins["#{path}:#{site.line}"] = site }
      elapsed = result.elapsed.total_milliseconds.round
      puts "macros (#{target.wire}): #{file.defs.size} generated defs kept of " \
           "#{collected.defs.size} in #{elapsed}ms"
      result.excluded.each do |left_out, reason|
        relative = left_out.sub(root + "/", "")
        puts "macros (#{target.wire}): left out #{relative}: #{reason.lines.first?}"
      end
      return result.files.to_set
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

  private def in_target(
    targets : Array(Heucristic::Index::Def),
    files : Set(String)?,
    root : String,
  ) : Array(Heucristic::Index::Def)
    return targets unless files

    targets.select do |entry|
      !entry.path.starts_with?(root + "/") || files.includes?(entry.path)
    end
  end

  private def percent(part : Int32, whole : Int32) : String
    whole.zero? ? "0%" : "#{(part * 100 // whole)}%"
  end
end

exit Score.run(ARGV)
