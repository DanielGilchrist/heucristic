require "compiler/crystal/syntax"
require "./constructed_placement"
require "./slot"
require "./type_reader"

module Heucristic
  module Syntax
    record FreePlacement
    record DeclaredPlacement, type : TypeReader::Outcome
    record InstanceVarPlacement, name : String
    record LocalPlacement, name : String
    record ArgumentPlacement, call : Crystal::Call, slot : Slot

    alias Placement = FreePlacement | DeclaredPlacement | InstanceVarPlacement | LocalPlacement |
                      ArgumentPlacement | ConstructedPlacement
  end
end
