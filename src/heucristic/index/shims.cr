require "./file"

module Heucristic
  module Index
    class Shims
      record Shim, entry : Def

      def initialize : Nil
        @by_identity = Hash(String, Shim).new
      end

      def size : Int32
        @by_identity.size
      end

      def replace_all(files : Array(File)) : Nil
        @by_identity.clear
        files.each do |file|
          file.defs.each { |entry| @by_identity[entry.identity] = Shim.new(entry) }
        end
      end

      def find(entry : Def) : Shim?
        @by_identity[entry.identity]?
      end

      def each(& : Shim ->) : Nil
        @by_identity.each_value { |shim| yield shim }
      end
    end
  end
end
