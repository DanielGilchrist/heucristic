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
        enclosing = name.rpartition("::")[0]
        enclosing.empty? ? TopLevel.new : Public.new(enclosing)
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
        enclosing = name.rpartition("::")[0]
        enclosing.empty? ? TopLevel.new : FilePrivate.new(enclosing, path)
      end

      def to_s(io : IO) : Nil
        io << name
      end
    end

    alias Identity = Public | FilePrivate
  end
end
