require "./def"
require "./namespace"
require "./alias"

module Heucristic
  module Index
    alias Entry = Def | Namespace | Alias
  end
end
