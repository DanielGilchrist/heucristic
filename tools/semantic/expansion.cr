require "json"

module Semantic
  record Expansion,
    path : String,
    line : Int32,
    column : Int32,
    name : String,
    source : String do
    include JSON::Serializable
  end
end
