require "./example"
require "./skip"

module Heucristic
  module Check
    class Tally
      getter skips = Hash(Skip, Int32).new(0)
      getter examples = Hash(Skip, Example).new
      getter unknown_receivers = Hash(String, Int32).new(0)
      getter unsettled_types = Hash(String, Int32).new(0)
      getter macro_calls = Hash(String, Int32).new(0)

      def merge(other : Tally) : Nil
        other.skips.each { |skip, count| @skips[skip] += count }
        other.examples.each { |skip, example| @examples[skip] ||= example }
        other.unknown_receivers.each { |detail, count| @unknown_receivers[detail] += count }
        other.unsettled_types.each { |type, count| @unsettled_types[type] += count }
        other.macro_calls.each { |name, count| @macro_calls[name] += count }
      end
    end
  end
end
