require "./file"

module Heucristic
  module Index
    class Shims
      def initialize : Nil
        @by_identity = Hash(String, Def).new
        @by_unrestricted = Hash(String, Array(Def)).new
      end

      def size : Int32
        @by_identity.size
      end

      def replace_all(files : Array(File)) : Nil
        @by_identity.clear
        @by_unrestricted.clear
        files.each do |file|
          file.defs.each do |entry|
            @by_identity[entry.identity] = entry
            (@by_unrestricted[entry.unrestricted_identity] ||= Array(Def).new) << entry
          end
        end
      end

      def find(entry : Def) : Def?
        exact = @by_identity[entry.identity]?
        exact || @by_unrestricted[entry.unrestricted_identity]?.try do |candidates|
          candidates.find { |shim| refines?(shim, entry) }
        end
      end

      def each(& : Def ->) : Nil
        @by_identity.each_value { |shim| yield shim }
      end

      private def refines?(shim : Def, entry : Def) : Bool
        shim.parameters.zip(entry.parameters).all? do |mine, theirs|
          next true if theirs.kind.block? || theirs.restriction.is_a?(Unrestricted)

          mine.restriction == theirs.restriction
        end
      end
    end
  end
end
