module Heucristic
  module Check
    enum Rule
      UndefinedMethod
      WrongArity
      BlockMismatch
      TypeMismatch
      NonExhaustiveCase
      AbstractNotImplemented
      AbstractInstantiated
      NoSuperclassMethod
      NoPreviousDef
      WrongTypeArguments
      NotGeneric
      MisplacedControl
      NamedArgument
      UndefinedOnMember
      UndefinedConstant
      ReturnMismatch
      UnknownInstanceVar
      InstanceVarMismatch
      UninitializedInstanceVar
      PrivateCall
      ProtectedCall

      def code : String
        to_s.underscore.gsub('_', '-')
      end
    end
  end
end
