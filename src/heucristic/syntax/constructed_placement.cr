require "./operation"
require "./slot"
require "./type_reader"

module Heucristic
  module Syntax
    record ConstructedPlacement,
      type : TypeReader::Outcome,
      operation : Operation,
      slot : PositionalSlot
  end
end
