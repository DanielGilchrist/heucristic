require "./resolution"

module Heucristic
  module Resolve
    record Binding, name : String, value : Resolution
  end
end
