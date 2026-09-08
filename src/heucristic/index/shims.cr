require "./file"

module Heucristic
  module Index
    class Shims
      record Shim, entry : Def

      def initialize : Nil
        @by_identity = Hash(String, Shim).new
        @by_shape = Hash(String, Array(Shim)).new
      end

      def size : Int32
        @by_identity.size
      end

      def replace_all(files : Array(File)) : Nil
        @by_identity.clear
        @by_shape.clear
        files.each do |file|
          file.defs.each do |entry|
            shim = Shim.new(entry)
            @by_identity[entry.identity] = shim
            (@by_shape[entry.shape] ||= Array(Shim).new) << shim
          end
        end
      end

      def find(entry : Def) : Shim?
        exact = @by_identity[entry.identity]?
        exact || @by_shape[entry.shape]?.try(&.find { |shim| refines?(shim.entry, entry) })
      end

      def each(& : Shim ->) : Nil
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
