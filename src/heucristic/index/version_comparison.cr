module Heucristic
  module Index
    enum VersionComparison
      AtLeast
      Above
      AtMost
      Below
      Equal
      Unequal

      def self.from_operator(operator : String) : VersionComparison?
        each { |comparison| return comparison if comparison.operator == operator }
        nil
      end

      def operator : String
        case self
        in .at_least? then ">="
        in .above?    then ">"
        in .at_most?  then "<="
        in .below?    then "<"
        in .equal?    then "=="
        in .unequal?  then "!="
        end
      end

      def holds?(comparison : Int32) : Bool
        case self
        in .at_least? then comparison >= 0
        in .above?    then comparison > 0
        in .at_most?  then comparison <= 0
        in .below?    then comparison < 0
        in .equal?    then comparison == 0
        in .unequal?  then comparison != 0
        end
      end
    end
  end
end
