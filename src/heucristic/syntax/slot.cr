module Heucristic
  module Syntax
    record PositionalSlot, index : Int32
    record NamedSlot, name : String

    alias Slot = PositionalSlot | NamedSlot
  end
end
