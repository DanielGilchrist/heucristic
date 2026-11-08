module Heucristic
  module Index
    module StaleShims
      record Entry, path : String, touched : Time

      MAX_AGE = 7.days

      def self.expired(
        entries : Array(Entry),
        keep : String,
        now : Time,
        max_age : Time::Span = MAX_AGE,
      ) : Array(String)
        entries.compact_map do |entry|
          entry.path if entry.path != keep && now - entry.touched > max_age
        end
      end
    end
  end
end
