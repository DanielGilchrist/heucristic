require "../../src/heucristic/index/accessor"
require "../../src/heucristic/syntax/uses"
require "./audit"
require "./call_targets"
require "./corpus"
require "./options"
require "./outcome"
require "./statements"

module Score
  class Scan
    def initialize(@corpus : Corpus, @options : Options) : Nil
    end

    def run : Int32
      outcomes = Array(Outcome).new
      at = @options.at
      elapsed = Time.measure do
        inspect_line(at) if at
        paths(at).each { |path| score_file(path, at, outcomes) }
      end

      report(outcomes, elapsed)
      verification = @options.verification
      Audit.new(@corpus, @options.only).run(outcomes, verification) if verification
      0
    end

    private def paths(at : At?) : Array(String)
      return @corpus.sites.map(&.path).sort! if at

      Dir.glob(File.join(@corpus.root, "src", "**", "*.cr")).sort
    end

    private def score_file(path : String, at : At?, outcomes : Array(Outcome)) : Nil
      relative = @corpus.relative(path)
      return if at && at.file != relative

      tree = Heucristic::Syntax.parse(File.read(path), path)
      return unless tree.is_a?(Crystal::ASTNode)

      version = @corpus.workspace.crystal_version
      Heucristic::Syntax::Uses.in(tree, path, version).calls.each do |site|
        call = site.call
        next if Statements::NAMES.includes?(call.name) && call.obj.nil?
        next if inside_macro_arguments?(site.context.ancestors)
        location = call.name_location
        next unless location

        result = @corpus.receiver.result_of(call, Heucristic::Resolve::Frame.of(site.context))
        if at && at.covers?(relative, location.line_number, location.column_number)
          explain(at, call, site, result)
        end
        outcomes << Outcome.new(
          path, location.line_number, location.column_number, call.name, result,
          CallTargets.new(@corpus.receiver).of(call, site.context),
          interpolated?(site.context.ancestors)
        )
      end
    end

    private def explain(
      at : At,
      call : Crystal::Call,
      site : Heucristic::Syntax::Uses::CallSite,
      result : Heucristic::Resolve::Resolution,
    ) : Nil
      receiver = @corpus.receiver
      typed = receiver.of_call(call, site.context)
      puts "#{call.name} at #{at.text}: #{result}"
      puts "  receiver: #{typed}"
      shape = receiver.shape_of(call, site.context)
      puts "  arguments: #{shape.types.join(", ")} precisions: #{shape.arguments.map(&.precision)}"
      if typed.is_a?(Heucristic::Resolve::Resolved)
        @corpus.methods.named_on(typed, call.name, site.context.path).each do |entry|
          rejected = @corpus.methods.rejected_argument(entry, shape, admission: :check)
          verdict = rejected ? "rejects #{rejected.actual} for #{rejected.expected}" : "accepts"
          puts "  #{entry.signature}: #{verdict}"
        end
      end
      chain = site.context.ancestors.map(&.class.name.sub("Crystal::", ""))
      puts "  ancestors: #{chain.join(" > ")}"
      puts "  def: #{site.context.def_node.try(&.name)}, blocks: #{site.context.blocks.size}"
    end

    private def inspect_line(at : At) : Nil
      sites = @corpus.sites.find { |candidate| candidate.path == File.join(@corpus.root, at.file) }
      return puts "no indexed sites for #{at.file}" unless sites

      environment = @corpus.environment(@corpus.settled)
      findings = Heucristic::Check::Calls.new(environment).run(sites).findings
      Heucristic::Check::Returns.new(environment).run(sites, findings)
      findings.each do |finding|
        next unless (finding.span.start_line.to_i64 + 1 - at.line.to_i64).abs <= 40

        puts "check: #{finding.rule.code} #{finding.message.lines.first?}"
        puts "check:   spans lines #{finding.span.start_line + 1}-#{finding.span.end_line + 1}"
      end
      on_line = sites.calls.count { |site| site.call.name_location.try(&.line_number) == at.line }
      puts "check: #{on_line} calls on the line"
    end

    private def report(outcomes : Array(Outcome), elapsed : Time::Span) : Nil
      resolved, unknown = outcomes.partition(&.result.is_a?(Heucristic::Resolve::Resolved))
      puts "#{outcomes.size} calls in #{@corpus.root}/src scored in " \
           "#{elapsed.total_milliseconds.round}ms"
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
          where = "#{@corpus.relative(first.path)}:#{first.line}:#{first.column}"
          puts "      #{sites.size.to_s.rjust(4)}x #{detail}  e.g. #{where}"
        end
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
      Statements::DECLARATIONS.includes?(name) || !Heucristic::Index::Accessor.from_name(name).nil?
    end

    private def percent(part : Int32, whole : Int32) : String
      whole.zero? ? "0%" : "#{(part * 100 // whole)}%"
    end
  end
end
