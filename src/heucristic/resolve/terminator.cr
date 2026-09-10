require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    module Terminator
      abstract def terminates?(call : Crystal::Call) : Bool
    end
  end
end
