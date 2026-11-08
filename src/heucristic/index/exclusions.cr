require "./exclusion"

module Heucristic
  module Index
    struct Exclusions
      include Enumerable(Exclusion)

      def self.none : Exclusions
        new(Array(Exclusion).new)
      end

      def initialize(@entries : Array(Exclusion)) : Nil
      end

      def each(& : Exclusion ->) : Nil
        @entries.each { |entry| yield entry }
      end

      def plus(path : String, reason : String) : Exclusions
        added = Array(Exclusion).new(@entries.size + 1)
        added.concat(@entries)
        added << Exclusion.new(path, reason)
        Exclusions.new(added)
      end

      def excludes?(path : String) : Bool
        @entries.any? { |entry| entry.path == path }
      end

      def reject_from(files : Array(String)) : Array(String)
        files.reject { |file| excludes?(file) }
      end

      def note(root : String) : String?
        return if @entries.empty?

        parts = @entries.join(", ") do |entry|
          "#{entry.path.sub(root + "/", "")} (#{entry.summary})"
        end
        "left out of the expansion because it failed: #{parts}"
      end
    end
  end
end
