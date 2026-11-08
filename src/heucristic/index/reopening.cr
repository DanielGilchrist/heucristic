require "json"

module Heucristic
  module Index
    record Reopening, name : String, private_to : String? do
      include JSON::Serializable
    end
  end
end
