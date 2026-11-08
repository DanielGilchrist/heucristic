module Heucristic
  module Index
    record Exclusion, path : String, reason : String do
      def summary : String
        reason.lines.first? || reason
      end
    end
  end
end
