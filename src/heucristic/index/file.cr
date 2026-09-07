require "./def"

module Heucristic
  module Index
    record File, path : String, defs : Array(Def)
  end
end
