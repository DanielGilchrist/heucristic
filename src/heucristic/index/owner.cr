require "./identity"

module Heucristic
  module Index
    record TopLevel

    alias Owner = Identity | TopLevel
  end
end
