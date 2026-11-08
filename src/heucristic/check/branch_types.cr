require "compiler/crystal/syntax"
require "../resolve/types"
require "../resolve/scope"
require "../syntax/type_reader"
require "../core_type"

module Heucristic
  module Check
    struct BranchTypes
      def initialize(@types : Resolve::Types, @scope : Resolve::Scope) : Nil
      end

      def named_by(cond : Crystal::ASTNode) : Index::Identity?
        return CoreType::Nil.identity if cond.is_a?(Crystal::NilLiteral)
        return unless cond.is_a?(Crystal::Path) || cond.is_a?(Crystal::Generic)

        read = Syntax::TypeReader.read(cond)
        return unless read.is_a?(Syntax::Type)

        resolved = @types.resolve_lexically(read, @scope)
        resolved.is_a?(Resolve::TypeRef) ? resolved.identity : nil
      end

      def covers?(covering : Index::Identity, member : Index::Identity) : Bool
        return true if covering == member

        chain = @types.ancestors(member)
        !chain.is_a?(Resolve::Unknown) && chain.includes?(covering)
      end
    end
  end
end
