require "../audit"
require "../call_targets"
require "../corpus"
require "../options"
require "../outcome"
require "./group"
require "./judge"

module Score
  module Features
    class Verification
      SEED = 7

      def initialize(@corpus : Corpus, @options : Options, @definitions : Set(Place)) : Nil
      end

      def run(pool : Array(Observation), count : Int32) : Int32
        puts
        puts "verifying up to #{count} answered positions per group"
        failures = 0
        Group.each do |group|
          next if group.call?

          failures += declarations(group, pool, count)
        end
        calls(pool, count)
        failures.zero? ? 0 : 2
      end

      private def declarations(group : Group, pool : Array(Observation), count : Int32) : Int32
        sample = pick(pool.select { |observation| observation.site.kind.group == group }, count)
        judge = Judge.new(@definitions)
        passed = 0
        skipped = Hash(String, Int32).new(0)
        failures = Array(String).new
        sample.each do |observation|
          case (judgement = judge.judge(observation))
          in Passed
            passed += 1
          in Skipped
            skipped[judgement.reason] += 1
          in Failed
            failures << "#{where(observation)} #{observation.site.name}: #{judgement.message}"
          end
        end
        puts "#{group.label}: #{sample.size} sampled, #{passed} verified, " \
             "#{failures.size} failed, #{skipped.values.sum} skipped"
        skipped.to_a.sort_by { |reason, _| reason }.each do |reason, total|
          puts "  skipped #{total}: #{reason}"
        end
        failures.each { |failure| puts "  FAIL #{failure}" }
        failures.size
      end

      private def calls(pool : Array(Observation), count : Int32) : Nil
        main = @options.main
        unless main
          puts "calls: pass --main <file> to verify against the compiler"
          return
        end

        calls = pool.select { |observation| observation.site.kind.group.try(&.call?) }
        outcomes = pick(calls, count).compact_map { |observation| outcome_of(observation) }
        Audit.new(@corpus, @options.only).run(outcomes, Options::Verification.new(count, main))
      end

      private def outcome_of(observation : Observation) : Outcome?
        target = observation.target
        return unless target.is_a?(Heucristic::Syntax::OnCall)

        call = target.node
        result = @corpus.receiver.result_of(call, Heucristic::Resolve::Frame.of(target.context))
        Outcome.new(
          observation.path, observation.site.line, observation.site.column, call.name, result,
          CallTargets.new(@corpus.receiver).of(call, target.context),
          target.context.ancestors.any?(Crystal::StringInterpolation)
        )
      end

      private def pick(pool : Array(Observation), count : Int32) : Array(Observation)
        pool.sample(Math.min(count, pool.size), Random.new(SEED))
      end

      private def where(observation : Observation) : String
        place = observation.place
        "#{@corpus.relative(place.path)}:#{place.line}:#{place.column}"
      end
    end
  end
end
