module Heucristic
  module Syntax
    enum ControlKind
      Yield
      Return
      Break
      Next

      def keyword : String
        to_s.downcase
      end
    end
  end
end
