require "compiler/crystal/syntax"
require "./placement"
require "./type_reader"

module Heucristic
  module Syntax
    module Placements
      extend self

      def of(
        node : Crystal::NumberLiteral | Crystal::SymbolLiteral,
        ancestors : Array(Crystal::ASTNode),
      ) : Placement
        parent = ancestors[-2]?
        case parent
        in Crystal::TypeDeclaration then typed_value(parent, node)
        in Crystal::Arg             then parameter_default(parent, node, ancestors[-3]?)
        in Crystal::Assign          then assigned(parent, node)
        in Crystal::ArrayLiteral    then array_element(parent, node)
        in Crystal::HashLiteral     then hash_entry(parent, node)
        in Crystal::Call            then positional(parent, node)
        in Crystal::NamedArgument   then named(parent, node, ancestors[-3]?)
        in Nil, Crystal::ASTNode    then FreePlacement.new
        end
      end

      private def typed_value(
        parent : Crystal::TypeDeclaration,
        node : Crystal::ASTNode,
      ) : Placement
        return FreePlacement.new unless parent.value.same?(node)

        declared(parent.declared_type)
      end

      private def parameter_default(
        parent : Crystal::Arg,
        node : Crystal::ASTNode,
        enclosing : Crystal::ASTNode?,
      ) : Placement
        return FreePlacement.new unless parent.default_value.same?(node)

        written = enclosing.is_a?(Crystal::EnumDef) ? enclosing.base_type : parent.restriction
        written ? declared(written) : FreePlacement.new
      end

      private def assigned(parent : Crystal::Assign, node : Crystal::ASTNode) : Placement
        return FreePlacement.new unless parent.value.same?(node)

        target = parent.target
        case target
        in Crystal::InstanceVar, Crystal::ClassVar then InstanceVarPlacement.new(target.name)
        in Crystal::Var                            then LocalPlacement.new(target.name)
        in Crystal::ASTNode                        then FreePlacement.new
        end
      end

      private def array_element(parent : Crystal::ArrayLiteral, node : Crystal::ASTNode) : Placement
        return FreePlacement.new unless parent.elements.any?(&.same?(node))

        name = parent.name
        return constructed(name, Operation::Append, 0) if name

        element_type = parent.of
        element_type ? declared(element_type) : FreePlacement.new
      end

      private def hash_entry(parent : Crystal::HashLiteral, node : Crystal::ASTNode) : Placement
        entry = parent.entries.find do |candidate|
          candidate.key.same?(node) || candidate.value.same?(node)
        end
        return FreePlacement.new unless entry

        name = parent.name
        return constructed(name, Operation::Store, entry.key.same?(node) ? 0 : 1) if name

        written = parent.of
        return FreePlacement.new unless written

        declared(entry.key.same?(node) ? written.key : written.value)
      end

      private def positional(parent : Crystal::Call, node : Crystal::ASTNode) : Placement
        index = parent.args.index(&.same?(node))
        return FreePlacement.new unless index

        ArgumentPlacement.new(parent, PositionalSlot.new(index))
      end

      private def named(
        parent : Crystal::NamedArgument,
        node : Crystal::ASTNode,
        call : Crystal::ASTNode?,
      ) : Placement
        return FreePlacement.new unless call.is_a?(Crystal::Call) && parent.value.same?(node)

        ArgumentPlacement.new(call, NamedSlot.new(parent.name))
      end

      private def declared(type : Crystal::ASTNode) : DeclaredPlacement
        DeclaredPlacement.new(TypeReader.read(type))
      end

      private def constructed(
        name : Crystal::ASTNode,
        operation : Operation,
        index : Int32,
      ) : ConstructedPlacement
        ConstructedPlacement.new(TypeReader.read(name), operation, PositionalSlot.new(index))
      end
    end
  end
end
