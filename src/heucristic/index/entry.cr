require "./def"
require "./namespace"
require "./alias"
require "./instance_var"
require "./constant"

module Heucristic
  module Index
    alias Entry = Def | Namespace | Alias | InstanceVar | Constant
  end
end
