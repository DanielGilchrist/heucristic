module Heucristic
  module Index
    class Table(T)
      def initialize : Nil
        @groups = Hash(String, Array(T)).new
      end

      def add(key : String, entry : T) : Nil
        (@groups[key] ||= Array(T).new) << entry
      end

      def drop(key : String, & : T -> Bool) : Nil
        remaining = @groups[key]?
        return unless remaining

        remaining.reject! { |entry| yield entry }
        @groups.delete(key) if remaining.empty?
      end

      def entries(key : String) : Array(T)
        @groups[key]? || Array(T).new
      end

      def has_key?(key : String) : Bool
        @groups.has_key?(key)
      end

      def each_group(& : Array(T) ->) : Nil
        @groups.each_value { |group| yield group }
      end
    end
  end
end
