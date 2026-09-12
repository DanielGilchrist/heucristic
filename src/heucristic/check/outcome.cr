require "./finding"
require "./skip"

module Heucristic
  module Check
    record Outcome,
      findings : Array(Finding),
      checked : Int32,
      skips : Hash(Skip, Int32),
      examples : Hash(Skip, String),
      unknown_receivers : Hash(String, Int32),
      unsettled_types : Hash(String, Int32)
  end
end
