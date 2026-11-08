require "../../src/heucristic/index/accessor"

module Score
  module Statements
    BARE         = {"require", "raise", "puts", "p", "pp"}
    DECLARATIONS = {
      "record", "delegate", "def_equals", "def_hash", "def_equals_and_hash", "forward_missing_to",
      "def_clone",
    }
    NAMES = Heucristic::Index::Accessor.names + BARE.to_a + DECLARATIONS.to_a
  end
end
