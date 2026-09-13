module Heucristic
  module Index
    enum MacroEffect
      Declaring
      Expression

      def declaring? : Bool
        self == Declaring
      end

      def expression? : Bool
        self == Expression
      end
    end
  end
end
