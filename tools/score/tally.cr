require "../../src/heucristic/check/outcome"

module Score
  class Tally
    getter checked = 0
    getter calls = 0
    getter findings = 0
    getter skips = Hash(Heucristic::Check::Skip, Int32).new(0)
    getter examples = Hash(Heucristic::Check::Skip, String).new
    getter unknown_receivers = Hash(String, Int32).new(0)
    getter unsettled_types = Hash(String, Int32).new(0)
    getter macro_calls = Hash(String, Int32).new(0)
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
      outcome.skips.each { |skip, count| @skips[skip] += count }
      outcome.examples.each { |skip, where| @examples[skip] ||= where }
      outcome.unknown_receivers.each { |detail, count| @unknown_receivers[detail] += count }
      outcome.unsettled_types.each { |type, count| @unsettled_types[type] += count }
      outcome.macro_calls.each { |name, count| @macro_calls[name] += count }
    end
  end
end
