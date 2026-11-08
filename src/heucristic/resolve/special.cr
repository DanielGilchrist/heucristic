require "../index/def"
require "./special_lookup"

module Heucristic
  module Resolve
    enum Special
      ObjectClass
      EnumValue
      ArrayCompact
      ProcCall
      TupleFirst
      TupleLast
      TupleFirstOrNil
      TupleLastOrNil
      TupleMap
      NamedTupleValues
      NamedTupleKeys
      ShouldNot
      EnumerableZip
      EnumerableZipOrNil
      EnumerableToH
      EnumEach
      Loop

      def self.for(entry : Index::Def) : Special?
        SpecialLookup.find(entry)
      end
    end
  end
end
