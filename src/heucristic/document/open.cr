require "./text"

module Heucristic
  module Document
    record Open, uri : String, version : Int32, text : Text
  end
end
