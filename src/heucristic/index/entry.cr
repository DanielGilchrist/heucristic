require "./def"
require "./namespace"
require "./alias"
require "./instance_var"

module Heucristic
  module Index
    alias Entry = Def | Namespace | Alias | InstanceVar
  end
end
