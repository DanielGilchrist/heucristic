require "./sites"

module Heucristic
  module Index
    record PathUse, sites : Sites, path : Crystal::Path, context : Syntax::Context
  end
end
