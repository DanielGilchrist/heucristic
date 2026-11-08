module Heucristic
  module Index
    class Table(K, T)
      def initialize : Nil
        @groups = Hash(K, Array(T)).new
      end

      def add(key : K, entry : T) : Nil
        (@groups[key] ||= Array(T).new) << entry
      end

      def drop(key : K, & : T -> Bool) : Nil
        remaining = @groups[key]?
        return unless remaining

        remaining.reject! { |entry| yield entry }
        @groups.delete(key) if remaining.empty?
      end

      def entries(key : K) : Array(T)
        @groups[key]? || Array(T).new
      end

      def has_key?(key : K) : Bool
        @groups.has_key?(key)
      end

      def each_group(& : Array(T) ->) : Nil
        @groups.each_value { |group| yield group }
      end
    end
  end
end
