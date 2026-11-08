require "compiler/crystal/syntax"
require "../statements"
require "./site"

module Score
  module Features
    class Walker < Crystal::Visitor
      IDENTIFIER = /\A[A-Za-z_]\w*[?!]?\z/

      getter sites : Array(Site)

      def self.sites(tree : Crystal::ASTNode, source : String) : Array(Site)
        walker = new(source.lines)
        tree.accept(walker)
        walker.sites
      end

      def initialize(@lines : Array(String)) : Nil
        @sites = Array(Site).new
        @written = Set(UInt64).new
        @synthesized = Set(UInt64).new
        @ivar_arguments = Set(UInt64).new
        @type_depth = 0
      end

      def visit(node : Crystal::Call) : Bool
        location = node.name_location
        return true unless location && node.name_size > 0 && spelled_call?(node)

        emit(call_kind(node), location.line_number, location.column_number, node.name)
        true
      end

      def visit(node : Crystal::Block) : Bool
        node.args.each { |argument| block_parameter(argument) }
        node.unpacks.try(&.each_value { |unpacked| unpacked_parameters(unpacked) })
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::Def) : Bool
        mark_instance_var_arguments(node)
        location = node.name_location
        add(Kind::DefName, location, node.name) if location && node.name != "->"
        node.receiver.try(&.accept(self))
        node.args.each(&.accept(self))
        node.double_splat.try(&.accept(self))
        node.block_arg.try(&.accept(self))
        typed(node.return_type)
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::Arg) : Bool
        location = node.location
        if location && !node.name.empty?
          if @ivar_arguments.includes?(node.object_id)
            add(Kind::InstanceVarParameter, location, "@#{node.name}")
          else
            add(Kind::Parameter, location, node.name)
          end
        end
        typed(node.restriction)
        node.default_value.try(&.accept(self))
        false
      end

      def visit(node : Crystal::Var) : Bool
        location = node.location
        name = node.name
        return false unless location

        if name == "self"
          add(Kind::SelfReference, location, name)
        elsif !name.empty? && name != "_" && !name.starts_with?("__")
          kind = @written.includes?(node.object_id) ? Kind::LocalDefinition : Kind::LocalUse
          add(kind, location, name)
        end
        false
      end

      def visit(node : Crystal::InstanceVar) : Bool
        node.location.try { |location| add(Kind::InstanceVar, location, node.name) }
        false
      end

      def visit(node : Crystal::ClassVar) : Bool
        node.location.try { |location| add(Kind::ClassVar, location, node.name) }
        false
      end

      def visit(node : Crystal::Path) : Bool
        segments(node, @type_depth > 0 ? Kind::TypePath : Kind::ConstantPath)
        false
      end

      def visit(node : Crystal::Generic) : Bool
        node.name.accept(self)
        node.type_vars.each { |type_var| typed(type_var) }
        false
      end

      def visit(node : Crystal::Require) : Bool
        node.location.try do |location|
          emit(Kind::Require, location.line_number, location.column_number, node.string)
        end
        false
      end

      def visit(node : Crystal::Assign) : Bool
        return false if @synthesized.includes?(node.object_id)

        target = node.target
        if target.is_a?(Crystal::Var)
          @written << target.object_id
        elsif target.is_a?(Crystal::Path)
          segments(target, Kind::DeclarationPath)
          node.value.accept(self)
          return false
        end
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        target = node.target
        @written << target.object_id if target.is_a?(Crystal::Var)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.targets.each do |target|
          @written << target.object_id if target.is_a?(Crystal::Var)
        end
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        @written << var.object_id if var.is_a?(Crystal::Var)
        var.accept(self)
        typed(node.declared_type)
        node.value.try(&.accept(self))
        false
      end

      def visit(node : Crystal::UninitializedVar) : Bool
        var = node.var
        @written << var.object_id if var.is_a?(Crystal::Var)
        var.accept(self)
        typed(node.declared_type)
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        segments(node.name, Kind::DeclarationPath)
        typed(node.superclass)
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        segments(node.name, Kind::DeclarationPath)
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        segments(node.name, Kind::DeclarationPath)
        typed(node.base_type)
        node.members.each { |member| enum_member(member) }
        false
      end

      def visit(node : Crystal::LibDef | Crystal::AnnotationDef) : Bool
        segments(node.name, Kind::DeclarationPath)
        false
      end

      def visit(node : Crystal::Alias) : Bool
        segments(node.name, Kind::DeclarationPath)
        typed(node.value)
        false
      end

      def visit(node : Crystal::Cast | Crystal::NilableCast) : Bool
        node.obj.accept(self)
        typed(node.to)
        false
      end

      def visit(node : Crystal::IsA) : Bool
        node.obj.accept(self)
        typed(node.const)
        false
      end

      def visit(node : Crystal::Rescue) : Bool
        node.types.try(&.each { |type| typed(type) })
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::ArrayLiteral) : Bool
        node.elements.each(&.accept(self))
        typed(node.of)
        false
      end

      def visit(node : Crystal::HashLiteral) : Bool
        node.entries.each do |entry|
          entry.key.accept(self)
          entry.value.accept(self)
        end
        node.of.try do |entry|
          typed(entry.key)
          typed(entry.value)
        end
        false
      end

      def visit(node : Crystal::SizeOf | Crystal::InstanceSizeOf) : Bool
        typed(node.exp)
        false
      end

      def visit(
        node : Crystal::Annotation | Crystal::Macro | Crystal::MacroFor | Crystal::MacroIf |
               Crystal::MacroExpression | Crystal::MacroLiteral,
      ) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def mark_instance_var_arguments(definition : Crystal::Def) : Nil
        body = definition.body
        assigns = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        definition.args.each do |argument|
          assign = assigns.find do |candidate|
            next false unless candidate.is_a?(Crystal::Assign)

            target = candidate.target
            target.is_a?(Crystal::InstanceVar) && target.name == "@#{argument.name}" &&
              target.location == argument.location
          end
          next unless assign

          @synthesized << assign.object_id
          @ivar_arguments << argument.object_id
        end
      end

      private def call_kind(node : Crystal::Call) : Kind
        return Kind::CallWithReceiver if node.obj
        return Kind::StatementCall if Statements::NAMES.includes?(node.name)

        Kind::CallImplicit
      end

      private def block_parameter(argument : Crystal::Var) : Nil
        location = argument.location
        name = argument.name
        return if location.nil? || name.empty? || name.starts_with?("__")

        add(Kind::BlockParameter, location, name)
      end

      private def unpacked_parameters(node : Crystal::ASTNode) : Nil
        if node.is_a?(Crystal::Var)
          node.location.try { |location| add(Kind::UnpackedBlockParameter, location, node.name) }
        elsif node.is_a?(Crystal::Expressions)
          node.expressions.each { |inner| unpacked_parameters(inner) }
        elsif node.is_a?(Crystal::Splat)
          unpacked_parameters(node.exp)
        end
      end

      private def enum_member(member : Crystal::ASTNode) : Nil
        if member.is_a?(Crystal::Arg)
          member.location.try { |location| add(Kind::EnumMember, location, member.name) }
          member.default_value.try(&.accept(self))
        else
          member.accept(self)
        end
      end

      private def segments(path : Crystal::Path, kind : Kind) : Nil
        location = path.location
        return unless location

        offset = path.global? ? 2 : 0
        path.names.each do |name|
          column = location.column_number + offset
          emit(kind, location.line_number, column, name) if spelled?(location, column, name)
          offset += name.size + 2
        end
      end

      private def typed(node : Crystal::ASTNode?) : Nil
        return unless node

        @type_depth += 1
        node.accept(self)
        @type_depth -= 1
      end

      private def add(kind : Kind, location : Crystal::Location, name : String) : Nil
        column = location.column_number
        return unless spelled?(location, column, name)

        emit(kind, location.line_number, column, name)
      end

      private def emit(kind : Kind, line : Int32, column : Int32, name : String) : Nil
        @sites << Site.new(kind, line, column, name)
      end

      private def spelled_call?(node : Crystal::Call) : Bool
        return true unless IDENTIFIER.matches?(node.name.chomp('='))

        location = node.name_location
        !location.nil? && spelled?(location, location.column_number, node.name.chomp('='))
      end

      private def spelled?(location : Crystal::Location, column : Int32, name : String) : Bool
        line = @lines[location.line_number - 1]?
        return false unless line

        written = line[(column - 1)..]?
        !written.nil? && written.lchop('@').starts_with?(name.lchop('@'))
      end
    end
  end
end
