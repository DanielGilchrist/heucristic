require "./sites"

module Heucristic
  module Index
    record CallUse, sites : Sites, call : Crystal::Call, context : Syntax::Context
  end
end
