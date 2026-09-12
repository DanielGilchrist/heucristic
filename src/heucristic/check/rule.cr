module Heucristic
  module Check
    enum Rule
      UndefinedMethod
      WrongArity
      BlockMismatch
      TypeMismatch
      NonExhaustiveCase
      AbstractNotImplemented

      def code : String
        to_s.underscore.gsub('_', '-')
      end
    end
  end
end
