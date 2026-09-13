module Heucristic
  module Check
    enum Skip
      NoLocation
      MacroInvocation
      MacroArguments
      SelectCondition
      ImplicitObject
      ChainedComparison
      OrphanOutsideDef
      ReceiverUnknown
      ReceiverTypeVar
      UnionMemberNotType
      TypeUnsettled
      TypeHasSubclasses
      ProgramUnsettled
      YieldScopeUnknown

      def label : String
        to_s.underscore.gsub('_', ' ')
      end
    end
  end
end
