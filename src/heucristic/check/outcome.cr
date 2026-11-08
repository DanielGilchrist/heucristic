require "./finding"
require "./tally"

module Heucristic
  module Check
    record Outcome, findings : Array(Finding), checked : Int32, tally : Tally
  end
end
