require "./corpus"
require "./options"
require "./outcome"
require "./verifier"

module Score
  class Audit
    def initialize(@corpus : Corpus, @only : String?) : Nil
    end

    def run(outcomes : Array(Outcome), verification : Options::Verification) : Nil
      resolved = outcomes.select(&.result.is_a?(Heucristic::Resolve::Resolved))
      verifiable = resolved.reject(&.interpolated)
      sample = pick(verifiable, verification.count)
      puts
      puts "verifying #{sample.size} resolved calls against `crystal tool implementations`"
      left_out = resolved.size - verifiable.size
      puts "(#{left_out} resolved calls inside string interpolation are not verified: " \
           "the compiler tool answers for the interpolation, not the call)"
      verifier = Verifier.new(
        @corpus.root, verification.main, @corpus.workspace, @corpus.types, @corpus.origins
      )
      tally = Hash(Verifier::Kind, Int32).new(0)
      sample.each { |outcome| judge(verifier, outcome, tally) }
      Verifier::Kind.each do |kind|
        puts "#{kind.to_s.underscore.tr("_", " ")}: #{tally[kind]}"
      end
      puts "not verified inside string interpolation: #{left_out}"
    end

    private def pick(verifiable : Array(Outcome), count : Int32) : Array(Outcome)
      only = @only
      if only
        verifiable.select(&.location.ends_with?(only))
      else
        verifiable.sample(Math.min(count, verifiable.size), Random.new(7))
      end
    end

    private def judge(
      verifier : Verifier,
      outcome : Outcome,
      tally : Hash(Verifier::Kind, Int32),
    ) : Nil
      ours = in_target(outcome.targets)
      probe = Verifier::Probe.new(outcome.path, outcome.line, outcome.column, outcome.result.to_s)
      where = @corpus.relative(outcome.location)
      verdict = verifier.judge(probe, ours)
      return puts "  compiler failed at #{where}" unless verdict

      tally[verdict.kind] += 1
      return if verdict.kind.agree?

      puts "  #{marker(verdict.kind)} #{where} #{outcome.name}: #{verdict.message}"
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

    private def in_target(targets : Array(Heucristic::Index::Def)) : Array(Heucristic::Index::Def)
      files = @corpus.main_files
      return targets unless files

      targets.select do |entry|
        !entry.path.starts_with?(@corpus.root + "/") || files.includes?(entry.path)
      end
    end
  end
end
