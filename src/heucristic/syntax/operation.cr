module Heucristic
  module Syntax
    enum Operation
      Append
      Store

      def method_name : String
        case self
        in .append? then "<<"
        in .store?  then "[]="
        end
      end
    end
  end
end
