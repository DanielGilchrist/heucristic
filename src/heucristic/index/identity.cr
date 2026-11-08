module Heucristic
  module Index
    record Public, name : String do
      def private? : Bool
        false
      end

      def child(segment : String) : Identity
        Public.new("#{name}::#{segment}")
      end

      def parent : Owner
        separator = name.rindex("::")
        separator ? Public.new(name[0, separator]) : TopLevel.new
      end

      def to_s(io : IO) : Nil
        io << name
      end
    end

    record FilePrivate, name : String, path : String do
      def private? : Bool
        true
      end

      def child(segment : String) : Identity
        FilePrivate.new("#{name}::#{segment}", path)
      end

      def parent : Owner
        separator = name.rindex("::")
        separator ? FilePrivate.new(name[0, separator], path) : TopLevel.new
      end

      def to_s(io : IO) : Nil
        io << name
      end
    end

    alias Identity = Public | FilePrivate
  end
end
