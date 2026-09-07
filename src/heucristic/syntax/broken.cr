require "../document/point"

module Heucristic
  module Syntax
    record Broken, message : String, at : Document::Point, size : Int32?
  end
end
