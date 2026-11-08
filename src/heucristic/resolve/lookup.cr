module Heucristic
  module Resolve
    enum Lookup
      Lexical
      Inherited
      Any

      def ancestors? : Bool
        inherited? || any?
      end

      def constants? : Bool
        any?
      end
    end
  end
end
