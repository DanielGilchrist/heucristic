module Heucristic
  module Index
    enum ParameterKind
      Positional
      Splat
      Keyword
      DoubleSplat
      Block

      def same_prefix?(other : ParameterKind) : Bool
        unprefixed? ? other.unprefixed? : self == other
      end

      def unprefixed? : Bool
        case self
        in .positional?, .keyword?          then true
        in .splat?, .double_splat?, .block? then false
        end
      end
    end
  end
end
