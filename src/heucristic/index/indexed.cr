require "./file"
require "./sites"

module Heucristic
  module Index
    record Indexed, file : File, sites : Sites?
  end
end
