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
    end
  end
end
