require "compiler/crystal/syntax"
require "./terminator"
require "./local_assignments"

module Heucristic
  module Resolve
    module Flow
      extend self

      record Truthy, positive : Bool
      record IsA, types : Array(Crystal::ASTNode), positive : Bool
      record Assigned, value : Crystal::ASTNode
      record OrAssigned, value : Crystal::ASTNode
      record Reassigned, values : Array(Crystal::ASTNode), within : Array(Crystal::ASTNode)

      alias Step = Truthy | IsA | Assigned | OrAssigned | Reassigned

      def steps(
        name : String,
        ancestors : Array(Crystal::ASTNode),
        exits : Terminator,
      ) : Array(Step)
        steps = Array(Step).new
        ancestors.each_cons_pair do |parent, child|
          between(name, parent, child, steps, exits)
        end
        steps
      end

      private def between(
        name : String,
        parent : Crystal::ASTNode,
        child : Crystal::ASTNode,
        steps : Array(Step),
        exits : Terminator,
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
          sequence(name, parent.expressions, child, steps, exits)
        end
      end

      private def sequence(
        name : String,
        statements : Array(Crystal::ASTNode),
        child : Crystal::ASTNode,
        steps : Array(Step),
        exits : Terminator,
      ) : Nil
        statements.each do |statement|
          break if statement.same?(child)

          guard(name, statement, steps, exits)
        end
      end

      private def guard(
        name : String,
        statement : Crystal::ASTNode,
        steps : Array(Step),
        exits : Terminator,
      ) : Nil
        case statement
        when Crystal::Assign
          target = statement.target
          return unless target.is_a?(Crystal::Var) && target.name == name

          steps << Assigned.new(statement.value)
        when Crystal::OpAssign
          target = statement.target
          return unless target.is_a?(Crystal::Var) && target.name == name && statement.op == "||"

          steps << OrAssigned.new(statement.value)
        when Crystal::If
          branch = statement.then
          if branch.is_a?(Crystal::Assign) && assigns?(branch, name) && empty?(statement.else)
            values = [branch.value] of Crystal::ASTNode
            steps << Reassigned.new(values, [statement, branch] of Crystal::ASTNode)
          elsif exits?(branch, exits) && empty?(statement.else)
            condition(name, statement.cond, false, steps)
          elsif exits?(statement.else, exits) && empty?(branch)
            condition(name, statement.cond, true, steps)
          else
            nested(name, statement, steps)
          end
        when Crystal::Unless
          if exits?(statement.then, exits) && empty?(statement.else)
            condition(name, statement.cond, true, steps)
          else
            nested(name, statement, steps)
          end
        when Crystal::Or
          condition(name, statement.left, true, steps) if exits?(statement.right, exits)
        else
          nested(name, statement, steps)
        end
      end

      private def unwrapped(node : Crystal::ASTNode?) : Crystal::ASTNode?
        return node.expressions[0] if node.is_a?(Crystal::Expressions) && node.expressions.size == 1

        node
      end

      private def assigns?(node : Crystal::ASTNode, name : String) : Bool
        return false unless node.is_a?(Crystal::Assign)

        target = node.target
        target.is_a?(Crystal::Var) && target.name == name
      end

      private def nested(name : String, statement : Crystal::ASTNode, steps : Array(Step)) : Nil
        values = LocalAssignments.find(statement, name)
        steps << Reassigned.new(values, [statement] of Crystal::ASTNode) unless values.empty?
      end

      private def case_branch(
        name : String,
        parent : Crystal::Case,
        child : Crystal::ASTNode,
        steps : Array(Step),
      ) : Nil
        subject = unwrapped(parent.cond)
        if subject.is_a?(Crystal::Assign) && (target = subject.target).is_a?(Crystal::Var)
          return unless target.name == name

          steps << Assigned.new(subject.value)
        elsif !(subject.is_a?(Crystal::Var) && subject.name == name)
          return
        end

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
          obj = unwrapped(cond.obj)
          if obj.is_a?(Crystal::Assign) && (target = obj.target).is_a?(Crystal::Var)
            return unless target.name == name

            steps << Assigned.new(obj.value)
            steps << IsA.new([cond.const], positive)
          elsif obj.is_a?(Crystal::Var) && obj.name == name
            steps << IsA.new([cond.const], positive)
          end
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

      private def exits?(node : Crystal::ASTNode, exits : Terminator) : Bool
        case node
        when Crystal::Return, Crystal::Break, Crystal::Next then true
        when Crystal::Call                                  then exits.terminates?(node)
        when Crystal::Expressions
          node.expressions.last?.try { |last| exits?(last, exits) } || false
        else false
        end
      end

      private def empty?(node : Crystal::ASTNode?) : Bool
        node.nil? || node.is_a?(Crystal::Nop)
      end
    end
  end
end
