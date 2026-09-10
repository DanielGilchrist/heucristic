module Heucristic
  module Resolve
    record TypeRef, name : String, arguments : Array(Resolution) do
      def to_s(io : IO) : Nil
        io << name
        return if arguments.empty?

        io << '('
        arguments.join(io, ", ")
        io << ')'
      end
    end

    record UnionRef, members : Array(Resolution) do
      def to_s(io : IO) : Nil
        members.join(io, " | ")
      end
    end

    record MetaRef, of : TypeRef do
      def to_s(io : IO) : Nil
        io << of << ".class"
      end
    end

    record TypeVar, name : String do
      def to_s(io : IO) : Nil
        io << name
      end
    end

    alias Resolved = TypeRef | UnionRef | MetaRef | TypeVar

    record Unknown, reason : Reason, detail : String do
      enum Reason
        NoAnnotation
        UnresolvedName
        FreeVariable
        NonTypeArgument
        Unsupported
        Cycle
        InferenceNeeded
        TopLevel
        Ambiguous
        TooDeep
      end

      def to_s(io : IO) : Nil
        io << "unknown (" << reason.to_s.underscore.gsub('_', ' ') << ": " << detail << ')'
      end
    end

    alias Resolution = Resolved | Unknown
  end
end
