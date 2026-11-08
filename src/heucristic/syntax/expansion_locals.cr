require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    class ExpansionLocals < Crystal::Visitor
      PREFIX = "__expanded_"

      record Isolated,
        names : Set(String),
        nested : Set(String),
        assigned : Set(String),
        straight : Array(Crystal::Assign),
        type_ofs : Array(Crystal::TypeOf)

      def self.isolate(fragment : Crystal::ASTNode) : Isolated
        statements = fragment.is_a?(Crystal::Expressions) ? fragment.expressions : [fragment]
        straight = Array(Crystal::Assign).new
        statements.each { |statement| collect_straight(statement, straight) }
        renamer = new(straight.map(&.object_id).to_set)
        fragment.accept(renamer)
        Isolated.new(renamer.names, renamer.nested, renamer.assigned, straight, renamer.type_ofs)
      end

      def self.collect_straight(node : Crystal::ASTNode, into : Array(Crystal::Assign)) : Nil
        case node
        when Crystal::Expressions
          node.expressions.each { |expression| collect_straight(expression, into) }
        when Crystal::Assign
          collect_straight(node.value, into)
          into << node if node.target.is_a?(Crystal::Var)
        when Crystal::TupleLiteral
          node.elements.each { |element| collect_straight(element, into) }
        when Crystal::Call
          obj = node.obj
          collect_straight(obj, into) if obj
          node.args.each { |argument| collect_straight(argument, into) }
        end
      end

      getter names : Set(String)
      getter nested : Set(String)
      getter assigned : Set(String)
      getter type_ofs : Array(Crystal::TypeOf)

      def initialize(@top : Set(UInt64)) : Nil
        @names = Set(String).new
        @nested = Set(String).new
        @assigned = Set(String).new
        @type_ofs = Array(Crystal::TypeOf).new
      end

      def visit(node : Crystal::Assign) : Bool
        node.value.accept(self)
        target = node.target
        assign(target, @top.includes?(node.object_id)) if target.is_a?(Crystal::Var)
        false
      end

      def visit(node : Crystal::OpAssign) : Bool
        node.value.accept(self)
        target = node.target
        target.accept(self)
        assign(target, false) if target.is_a?(Crystal::Var)
        false
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.values.each(&.accept(self))
        node.targets.each do |target|
          target.is_a?(Crystal::Var) ? assign(target, false) : target.accept(self)
        end
        false
      end

      def visit(node : Crystal::Block) : Bool
        node.args.each { |argument| declare(argument, false) }
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::Rescue) : Bool
        name = node.name
        if name
          @assigned << name
          @names << PREFIX + name
          @nested << PREFIX + name
          node.name = PREFIX + name
        end
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::ProcLiteral) : Bool
        definition = node.def
        definition.args.each do |argument|
          @names << PREFIX + argument.name
          @nested << PREFIX + argument.name
          argument.name = PREFIX + argument.name
        end
        definition.body.accept(self)
        false
      end

      def visit(node : Crystal::TypeDeclaration | Crystal::UninitializedVar) : Bool
        var = node.var
        assign(var, false) if var.is_a?(Crystal::Var)
        false
      end

      def visit(node : Crystal::Var) : Bool
        renamed = PREFIX + node.name
        node.name = renamed if @names.includes?(renamed)
        false
      end

      def visit(node : Crystal::TypeOf) : Bool
        @type_ofs << node
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def assign(var : Crystal::Var, top : Bool) : Nil
        @assigned << var.name.lchop(PREFIX)
        declare(var, top)
      end

      private def declare(var : Crystal::Var, top : Bool) : Nil
        renamed = var.name.starts_with?(PREFIX) ? var.name : PREFIX + var.name
        @names << renamed
        @nested << renamed unless top
        var.name = renamed
      end
    end
  end
end
