require "compiler/crystal/syntax"
require "./owner"

module Heucristic
  module Index
    class FilePrivacy
      @marked : Crystal::ASTNode? = nil
      @roots : Set(String) = Set(String).new

      def initialize(@path : String?) : Nil
      end

      def modifier(node : Crystal::VisibilityModifier, enclosing : Owner) : Nil
        @marked = node.exp if node.modifier.private? && enclosing.is_a?(TopLevel)
      end

      def release : Nil
        @marked = nil
      end

      def private_declaration?(node : Crystal::ASTNode) : Bool
        @marked.try(&.same?(node)) || false
      end

      def identity(
        full : String,
        name : Crystal::Path,
        enclosing : Owner,
        declaration : Crystal::ASTNode?,
      ) : Identity
        file = @path
        return Public.new(full) unless file

        case enclosing
        in Identity
          enclosing.private? && !name.global? ? FilePrivate.new(full, file) : Public.new(full)
        in TopLevel
          if declaration && private_declaration?(declaration)
            @roots << name.names[0]
            FilePrivate.new(full, file)
          elsif !name.global? && name.names.size > 1 && @roots.includes?(name.names[0])
            FilePrivate.new(full, file)
          else
            Public.new(full)
          end
        end
      end
    end
  end
end
