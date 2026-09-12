module Heucristic
  module Server
    enum Stage
      Pending
      Done
      Stale
      Failed
      Unavailable

      def self.read(raw : JSON::Any?) : Stage?
        raw.try(&.["status"]?).try(&.as_s?).try { |name| parse?(name) }
      end

      def wire : String
        to_s.downcase
      end
    end
  end
end
