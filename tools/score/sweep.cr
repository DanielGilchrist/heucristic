require "./corpus"
require "./options"
require "./tally"
require "./timing"

module Score
  class Sweep
    BUDGET_MS = 25.0
    ROUNDS    =    3
    SLOWEST   =    3

    def initialize(@corpus : Corpus, @options : Options) : Nil
    end

    def run : Int32
      tally = Tally.new
      elapsed = Time.measure { sweep(tally) }
      puts "#{tally.findings} findings; #{tally.checked} of #{tally.calls} calls in " \
           "#{@corpus.sites.size} files were checkable " \
           "(#{elapsed.total_milliseconds.round}ms cold sweep)"
      explain(tally) if @options.why
      slowest = measure_warm.sort_by { |timing| -timing.milliseconds }.first(SLOWEST)
      slowest.each { |timing| puts "  #{timing.milliseconds.round(1)}ms #{timing.path}" }
      over = slowest.first?.try { |timing| timing.milliseconds > BUDGET_MS } || false
      puts "budget: #{BUDGET_MS}ms per warm file check #{over ? "EXCEEDED" : "met"}"
      return 3 if over

      tally.findings.zero? ? 0 : 2
    end

    private def sweep(tally : Tally) : Nil
      settled = @corpus.settled
      suite = @corpus.suite(settled)
      @corpus.sites.sort_by(&.path).each do |sites|
        next if skipped?(sites.path)
        next if @corpus.shim_roots.any? { |shim_root| sites.path.starts_with?(shim_root + "/") }

        tally.add_calls(sites.calls.size)
        tally.add_uncompiled(@corpus.relative(sites.path)) if settled.uncompiled_file?(sites.path)
        outcome = suite.run(sites)
        tally.absorb(outcome)
        outcome.findings.each do |finding|
          tally.add_finding
          where = "#{@corpus.relative(sites.path)}:#{finding.span.start_line + 1}"
          puts "#{where}: #{finding.rule.code}: #{finding.message}"
        end
      end
    end

    private def measure_warm : Array(Timing)
      timings = Array(Timing).new
      @corpus.sites.each do |sites|
        next if skipped?(sites.path)

        spent = Time.measure { ROUNDS.times { @corpus.suite(@corpus.settled).run(sites) } }
        timings << Timing.new(@corpus.relative(sites.path), spent.total_milliseconds / ROUNDS)
      end
      timings
    end

    private def skipped?(path : String) : Bool
      only = @options.only
      @corpus.in_lib?(path) || (!only.nil? && !path.ends_with?(only))
    end

    private def explain(tally : Tally) : Nil
      puts
      puts "not checkable because:"
      tally.skips.to_a.sort_by { |_, count| -count }.each do |skip, count|
        where = tally.examples[skip]?.try { |example| @corpus.relative(example) } || ""
        puts "  #{count.to_s.rjust(6)}  #{skip.label.ljust(22)} e.g. #{where}"
      end
      top("receivers the resolver could not type:", tally.unknown_receivers)
      top("receiver types that are not settled:", tally.unsettled_types)
      top("macro invocations skipped:", tally.macro_calls)
      return if tally.uncompiled.empty?

      puts "files no target compiled (#{tally.uncompiled.size}):"
      tally.uncompiled.first(12).each { |path| puts "  #{path}" }
    end

    private def top(title : String, counts : Hash(String, Int32)) : Nil
      return if counts.empty?

      puts
      puts title
      counts.to_a.sort_by { |_, count| -count }.first(12).each do |detail, count|
        puts "  #{count.to_s.rjust(6)}  #{detail}"
      end
    end
  end
end
