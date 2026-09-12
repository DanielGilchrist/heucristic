require "./finding"

module Heucristic
  module Check
    record Outcome, findings : Array(Finding), checked : Int32
  end
end
