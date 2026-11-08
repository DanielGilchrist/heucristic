require "../core_type"
require "../index/identity"

module Heucristic
  module Resolve
    record TypeRef,
      identity : Index::Identity,
      arguments : Array(Resolution),
      labels : Array(String) = Array(String).new do
      def self.of(core : CoreType) : TypeRef
        new(Index::Public.new(core.type_name), Array(Resolution).new)
      end

      def self.of(core : CoreType, arguments : Array(Resolution)) : TypeRef
        new(Index::Public.new(core.type_name), arguments)
      end

      def core : CoreType?
        current = identity
        current.is_a?(Index::Public) ? CoreType.from_name(current.name) : nil
      end

      def is?(core : CoreType) : Bool
        current = identity
        current.is_a?(Index::Public) && current.name == core.type_name
      end

      def labelled? : Bool
        !labels.empty?
      end

      def to_s(io : IO) : Nil
        io << identity
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
      def self.members_of(resolution : Resolution) : Array(Resolution)
        resolution.is_a?(UnionRef) ? resolution.members : [resolution] of Resolution
      end

      def self.join(members : Array(Resolution)) : Resolution
        return TypeRef.of(:no_return) if members.empty?

        members.uniq!
        members.size == 1 ? members[0] : new(members)
      end

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

    record ProgramRef do
      IDENTITY = Index::Public.new("top-level")

      def identity : Index::Identity
        IDENTITY
      end

      def to_s(io : IO) : Nil
        io << IDENTITY
      end
    end

    alias Resolved = TypeRef | UnionRef | MetaRef | TypeVar | ProgramRef

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
        Macro
      end

      def to_s(io : IO) : Nil
        io << "unknown (" << reason.to_s.underscore.gsub('_', ' ') << ": " << detail << ')'
      end
    end

    alias Resolution = Resolved | Unknown
  end
end
