require "./def"
require "./namespace"
require "./mixin"
require "./instance_var"
require "./alias"

module Heucristic
  module Index
    record File,
      path : String,
      defs : Array(Def),
      namespaces : Array(Namespace),
      mixins : Array(Mixin),
      instance_vars : Array(InstanceVar),
      aliases : Array(Alias)
  end
end
