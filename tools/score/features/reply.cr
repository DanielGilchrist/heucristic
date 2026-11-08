module Score
  module Features
    record Answered, located : Bool
    record Unanswered, reason : String, detail : String
    record Empty
    record Crashed, message : String

    alias Reply = Answered | Unanswered | Empty | Crashed
  end
end
