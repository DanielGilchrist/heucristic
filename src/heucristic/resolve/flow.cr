require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    module Flow
      extend self

      record Truthy, positive : Bool
      record IsA, types : Array(Crystal::ASTNode), positive : Bool
      record Assigned, value : Crystal::ASTNode

      alias Step = Truthy | IsA | Assigned

      EXITS = {"raise", "exit", "abort"}

      def steps(name : String, ancestors : Array(Crystal::ASTNode)) : Array(Step)
        steps = Array(Step).new
        ancestors.each_cons_pair do |parent, child|
          between(name, parent, child, steps)
        end
        steps
      end

      private def between(
        name : String,
        parent : Crystal::ASTNode,
        child : Crystal::ASTNode,
        steps : Array(Step),
      ) : Nil
        case parent
        when Crystal::If
          condition(name, parent.cond, true, steps) if parent.then.same?(child)
          condition(name, parent.cond, false, steps) if parent.else.same?(child)
        when Crystal::Unless
          condition(name, parent.cond, false, steps) if parent.then.same?(child)
          condition(name, parent.cond, true, steps) if parent.else.same?(child)
        when Crystal::While
          condition(name, parent.cond, true, steps) if parent.body.same?(child)
        when Crystal::Until
          condition(name, parent.cond, false, steps) if parent.body.same?(child)
        when Crystal::And
          condition(name, parent.left, true, steps) if parent.right.same?(child)
        when Crystal::Or
          condition(name, parent.left, false, steps) if parent.right.same?(child)
        when Crystal::Case
          case_branch(name, parent, child, steps)
        when Crystal::When
          nil
        when Crystal::Expressions
          sequence(name, parent.expressions, child, steps)
        end
      end

      private def sequence(
        name : String,
        statements : Array(Crystal::ASTNode),
        child : Crystal::ASTNode,
        steps : Array(Step),
      ) : Nil
        statements.each do |statement|
          break if statement.same?(child)

          guard(name, statement, steps)
        end
      end

      private def guard(name : String, statement : Crystal::ASTNode, steps : Array(Step)) : Nil
        case statement
        when Crystal::Assign
          target = statement.target
          return unless target.is_a?(Crystal::Var) && target.name == name

          steps << Assigned.new(statement.value)
        when Crystal::If
          if exits?(statement.then) && empty?(statement.else)
            condition(name, statement.cond, false, steps)
          elsif exits?(statement.else) && empty?(statement.then)
            condition(name, statement.cond, true, steps)
          end
        when Crystal::Unless
          return unless exits?(statement.then) && empty?(statement.else)

          condition(name, statement.cond, true, steps)
        when Crystal::Or
          condition(name, statement.left, true, steps) if exits?(statement.right)
        end
      end

      private def case_branch(
        name : String,
        parent : Crystal::Case,
        child : Crystal::ASTNode,
        steps : Array(Step),
      ) : Nil
        subject = parent.cond
        return unless subject.is_a?(Crystal::Var) && subject.name == name

        if (taken = parent.whens.find(&.same?(child)))
          types = type_conditions(taken.conds)
          steps << IsA.new(types, true) if types
        elsif parent.else.same?(child)
          all = Array(Crystal::ASTNode).new
          parent.whens.each do |branch|
            types = type_conditions(branch.conds)
            return unless types

            all.concat(types)
          end
          steps << IsA.new(all, false)
        end
      end

      private def type_conditions(conds : Array(Crystal::ASTNode)) : Array(Crystal::ASTNode)?
        types = Array(Crystal::ASTNode).new(conds.size)
        conds.each do |cond|
          case cond
          when Crystal::Path, Crystal::Generic then types << cond
          when Crystal::NilLiteral             then types << Crystal::Path.global("Nil")
          else                                      return
          end
        end
        types
      end

      private def condition(
        name : String,
        cond : Crystal::ASTNode,
        positive : Bool,
        steps : Array(Step),
      ) : Nil
        case cond
        when Crystal::Var
          steps << Truthy.new(positive) if cond.name == name
        when Crystal::IsA
          obj = cond.obj
          steps << IsA.new([cond.const], positive) if obj.is_a?(Crystal::Var) && obj.name == name
        when Crystal::Not
          condition(name, cond.exp, !positive, steps)
        when Crystal::And
          return unless positive

          condition(name, cond.left, true, steps)
          condition(name, cond.right, true, steps)
        when Crystal::Or
          return if positive

          condition(name, cond.left, false, steps)
          condition(name, cond.right, false, steps)
        when Crystal::Assign
          target = cond.target
          return unless target.is_a?(Crystal::Var) && target.name == name

          steps << Assigned.new(cond.value)
          steps << Truthy.new(positive)
        when Crystal::Expressions
          condition(name, cond.expressions[0], positive, steps) if cond.expressions.size == 1
        end
      end

      private def exits?(node : Crystal::ASTNode) : Bool
        case node
        when Crystal::Return, Crystal::Break, Crystal::Next then true
        when Crystal::Call
          node.obj.nil? && EXITS.includes?(node.name)
        when Crystal::Expressions
          node.expressions.last?.try { |last| exits?(last) } || false
        else false
        end
      end

      private def empty?(node : Crystal::ASTNode?) : Bool
        node.nil? || node.is_a?(Crystal::Nop)
      end
    end
  end
end
