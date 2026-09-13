require "compiler/crystal/syntax"

module Heucristic
  module Check
    class Declarations < Crystal::Visitor
      def self.within?(node : Crystal::ASTNode) : Bool
        visitor = new
        node.accept(visitor)
        visitor.found?
      end

      getter? found : Bool

      def initialize : Nil
        @found = false
      end

      def visit(
        node : Crystal::Def | Crystal::FunDef | Crystal::Macro | Crystal::ClassDef |
               Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef | Crystal::AnnotationDef |
               Crystal::Alias | Crystal::Include | Crystal::Extend | Crystal::InstanceVar |
               Crystal::ClassVar | Crystal::MacroExpression | Crystal::MacroIf | Crystal::MacroFor,
      ) : Bool
        @found = true
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        !@found
      end
    end
  end
end
