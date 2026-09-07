module Heucristic
  module Syntax
    class Named
      getter names : Array(String)
      getter? global : Bool

      def initialize(@names : Array(String), @global : Bool) : Nil
      end

      def_equals_and_hash names, global?

      def to_s(io : IO) : Nil
        io << "::" if global?
        names.join(io, "::")
      end
    end

    class Generic
      record NamedArgument, name : String, type : Type

      getter base : Named
      getter arguments : Array(Type)
      getter named_arguments : Array(NamedArgument)

      def initialize(
        @base : Named,
        @arguments : Array(Type),
        @named_arguments : Array(NamedArgument),
      ) : Nil
      end

      def_equals_and_hash base, arguments, named_arguments

      def to_s(io : IO) : Nil
        io << base << '('
        arguments.each_with_index do |argument, index|
          io << ", " if index > 0
          TypeWriter.nested(io, argument)
        end
        named_arguments.each_with_index do |argument, index|
          io << ", " if index > 0 || !arguments.empty?
          io << argument.name << ": "
          TypeWriter.nested(io, argument.type)
        end
        io << ')'
      end
    end

    class Union
      getter members : Array(Type)

      def initialize(@members : Array(Type)) : Nil
      end

      def_equals_and_hash members

      def to_s(io : IO) : Nil
        members.each_with_index do |member, index|
          io << " | " if index > 0
          TypeWriter.nested(io, member)
        end
      end
    end

    class Nilable
      getter inner : Type

      def initialize(@inner : Type) : Nil
      end

      def_equals_and_hash inner

      def to_s(io : IO) : Nil
        TypeWriter.nested(io, inner, wrap_unions: true)
        io << '?'
      end
    end

    class Proc
      getter inputs : Array(Type)
      getter output : Type?

      def initialize(@inputs : Array(Type), @output : Type?) : Nil
      end

      def_equals_and_hash inputs, output

      def to_s(io : IO) : Nil
        inputs.each_with_index do |input, index|
          io << ", " if index > 0
          TypeWriter.nested(io, input)
        end
        io << ' ' unless inputs.empty?
        io << "->"
        return unless (result = output)

        io << ' '
        TypeWriter.nested(io, result)
      end
    end

    class Metaclass
      getter of : Type

      def initialize(@of : Type) : Nil
      end

      def_equals_and_hash of

      def to_s(io : IO) : Nil
        TypeWriter.nested(io, of, wrap_unions: true)
        io << ".class"
      end
    end

    class Splat
      getter inner : Type

      def initialize(@inner : Type) : Nil
      end

      def_equals_and_hash inner

      def to_s(io : IO) : Nil
        io << '*'
        TypeWriter.nested(io, inner)
      end
    end

    class Literal
      getter source : String

      def initialize(@source : String) : Nil
      end

      def_equals_and_hash source

      def to_s(io : IO) : Nil
        io << source
      end
    end

    class TypeOf
      getter source : String

      def initialize(@source : String) : Nil
      end

      def_equals_and_hash source

      def to_s(io : IO) : Nil
        io << "typeof(" << source << ')'
      end
    end

    class SelfType
      def_equals_and_hash

      def to_s(io : IO) : Nil
        io << "self"
      end
    end

    class Underscore
      def_equals_and_hash

      def to_s(io : IO) : Nil
        io << '_'
      end
    end

    alias Type = Named |
                 Generic |
                 Union |
                 Nilable |
                 Proc |
                 Metaclass |
                 Splat |
                 Literal |
                 TypeOf |
                 SelfType |
                 Underscore

    module TypeWriter
      def self.nested(io : IO, type : Type, wrap_unions : Bool = false) : Nil
        wrap = type.is_a?(Proc) || (wrap_unions && type.is_a?(Union))
        io << '(' if wrap
        io << type
        io << ')' if wrap
      end
    end
  end
end
