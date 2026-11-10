module Score
  module Features
    record Answered, located : Bool
    record Unanswered, reason : String, detail : String
    record Untargeted
    record Empty
    record Crashed, message : String

    alias Reply = Answered | Unanswered | Untargeted | Empty | Crashed
  end
end
