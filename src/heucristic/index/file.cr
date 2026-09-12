require "./def"
require "./namespace"
require "./mixin"
require "./instance_var"
require "./alias"
require "./constant"
require "./macro_def"

module Heucristic
  module Index
    record File,
      path : String,
      defs : Array(Def),
      namespaces : Array(Namespace),
      mixins : Array(Mixin),
      instance_vars : Array(InstanceVar),
      aliases : Array(Alias),
      constants : Array(Constant),
      macros : Array(MacroDef) = Array(MacroDef).new
  end
end
