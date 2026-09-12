module Heucristic
  module Check
    enum Rule
      UndefinedMethod
      WrongArity
      BlockMismatch

      def code : String
        to_s.underscore.gsub('_', '-')
      end
    end
  end
end
