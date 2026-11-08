require "../../src/heucristic/check/outcome"

module Score
  class Tally
    getter checked = 0
    getter calls = 0
    getter findings = 0
    getter counts = Heucristic::Check::Tally.new
    getter uncompiled = Array(String).new

    def add_calls(count : Int32) : Nil
      @calls += count
    end

    def add_uncompiled(path : String) : Nil
      @uncompiled << path
    end

    def add_finding : Nil
      @findings += 1
    end

    def absorb(outcome : Heucristic::Check::Outcome) : Nil
      @checked += outcome.checked
      @counts.merge(outcome.tally)
    end
  end
end
