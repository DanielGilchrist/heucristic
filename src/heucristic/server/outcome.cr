module Heucristic
  module Server
    record Reply, body : String
    record Silence
    record Stop

    alias Outcome = Reply | Silence | Stop
  end
end
