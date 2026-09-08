require "./def"
require "./namespace"
require "./mixin"
require "./instance_var"
require "./alias"
require "./constant"

module Heucristic
  module Index
    record File,
      path : String,
      defs : Array(Def),
      namespaces : Array(Namespace),
      mixins : Array(Mixin),
      instance_vars : Array(InstanceVar),
      aliases : Array(Alias),
      constants : Array(Constant)
  end
end
