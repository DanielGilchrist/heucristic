module Score
  module Features
    record Passed
    record Failed, message : String
    record Skipped, reason : String

    alias Judgement = Passed | Failed | Skipped
  end
end
