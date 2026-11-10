require "compiler/crystal/syntax"
require "./block_inputs"
require "./local_declaration"
require "./not_declared"

module Heucristic
  module Resolve
    class LocalDeclarations < Crystal::Visitor
      def self.find(
        ancestors : Array(Crystal::ASTNode),
        name : String,
      ) : LocalDeclaration | NotDeclared
        (ancestors.size - 1).downto(0) do |index|
          scope = ancestors[index]
          case scope
          in Crystal::Block
            return NotDeclared.new if shadowed_by?(scope, name)

            found = run(scope.body, name)
            return found unless found.is_a?(NotDeclared)
          in Crystal::ProcLiteral
            return NotDeclared.new if scope.def.args.any?(&.name.==(name))

            found = run(scope.def.body, name)
            return found unless found.is_a?(NotDeclared)
          in Crystal::Def
            next if index > 0 && ancestors[index - 1].is_a?(Crystal::ProcLiteral)

            return boundary(scope.args, scope.body, name)
          in Crystal::ClassDef, Crystal::ModuleDef, Crystal::LibDef
            return run(scope.body, name)
          in Crystal::EnumDef, Crystal::Macro
            return NotDeclared.new
          in Crystal::ASTNode
            nil
          end
        end

        root = ancestors.first?
        root ? run(root, name) : NotDeclared.new
      end

      def initialize(@name : String) : Nil
        @found = nil
      end

      def found : LocalDeclaration | NotDeclared
        @found || NotDeclared.new
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        remember(node.declared_type, var) if var.is_a?(Crystal::Var) && var.name == @name
        @found.nil?
      end

      def visit(node : Crystal::UninitializedVar) : Bool
        var = node.var
        remember(node.declared_type, var) if var.is_a?(Crystal::Var) && var.name == @name
        @found.nil?
      end

      def visit(
        node : Crystal::Block | Crystal::ProcLiteral | Crystal::Def | Crystal::ClassDef |
               Crystal::ModuleDef | Crystal::LibDef | Crystal::EnumDef | Crystal::Macro,
      ) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        @found.nil?
      end

      private def remember(declared_type : Crystal::ASTNode, var : Crystal::Var) : Nil
        @found ||= LocalDeclaration.new(declared_type, var.location)
      end

      private def self.run(
        body : Crystal::ASTNode,
        name : String,
      ) : LocalDeclaration | NotDeclared
        finder = new(name)
        body.accept(finder)
        finder.found
      end

      private def self.boundary(
        parameters : Array(Crystal::Arg),
        body : Crystal::ASTNode,
        name : String,
      ) : LocalDeclaration | NotDeclared
        return NotDeclared.new if parameters.any?(&.name.==(name))

        run(body, name)
      end

      private def self.shadowed_by?(block : Crystal::Block, name : String) : Bool
        !BlockInputs.introduced(block, name).is_a?(BlockInputs::NotIntroduced)
      end
    end
  end
end
