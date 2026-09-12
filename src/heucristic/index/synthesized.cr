module Heucristic
  module Index
    enum Synthesized
      Record
      Delegate
      ForwardMissingTo

      def self.from_name(name : String) : Synthesized?
        each { |synthesized| return synthesized if synthesized.macro_name == name }
        nil
      end

      def macro_name : String
        case self
        in .record?             then "record"
        in .delegate?           then "delegate"
        in .forward_missing_to? then "forward_missing_to"
        end
      end
    end
  end
end
