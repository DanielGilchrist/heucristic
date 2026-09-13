module Heucristic
  module Index
    enum MacroEffect
      Declaring
      Expression

      def declaring? : Bool
        self == Declaring
      end
    end
  end
end
