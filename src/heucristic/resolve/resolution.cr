require "../core_type"

module Heucristic
  module Resolve
    record TypeRef,
      name : String,
      arguments : Array(Resolution),
      labels : Array(String) = Array(String).new do
      PROGRAM = "Program"

      def self.program : TypeRef
        new(PROGRAM, Array(Resolution).new)
      end

      def self.of(core : CoreType) : TypeRef
        new(core.type_name, Array(Resolution).new)
      end

      def self.of(core : CoreType, arguments : Array(Resolution)) : TypeRef
        new(core.type_name, arguments)
      end

      def program? : Bool
        name == PROGRAM && arguments.empty?
      end

      def is?(core : CoreType) : Bool
        name == core.type_name
      end

      def labelled? : Bool
        !labels.empty?
      end

      def to_s(io : IO) : Nil
        io << name
        return if arguments.empty?

        io << '('
        if labelled?
          labels.each_with_index do |label, index|
            io << ", " if index > 0
            io << label << ": " << arguments[index]
          end
        else
          arguments.join(io, ", ")
        end
        io << ')'
      end
    end

    record UnionRef, members : Array(Resolution) do
      def to_s(io : IO) : Nil
        members.join(io, " | ")
      end
    end

    record TypeVar, name : String do
      def to_s(io : IO) : Nil
        io << name
      end
    end

    record MetaRef, of : TypeRef | TypeVar do
      def to_s(io : IO) : Nil
        io << of << ".class"
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
