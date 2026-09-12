require "compiler/crystal/syntax"
require "./terminator"
require "./local_assignments"
require "./reassignment"

module Heucristic
  module Resolve
    class Flow
      record Truthy, positive : Bool
      record IsA, types : Array(Crystal::ASTNode), positive : Bool
      record Assigned, value : Crystal::ASTNode, within : Array(Crystal::ASTNode)
      record OrAssigned, value : Crystal::ASTNode, within : Array(Crystal::ASTNode)
      record Reassigned, values : Array(Reassignment), within : Array(Crystal::ASTNode)
      record Branch, positive : Bool, body : Crystal::ASTNode?
      record Branched,
        cond : Crystal::ASTNode,
        branches : Array(Branch),
        within : Array(Crystal::ASTNode),
        assigns : Bool

      alias Step = Truthy | IsA | Assigned | OrAssigned | Reassigned | Branched

      getter steps : Array(Step)

      def self.steps(
        name : String,
        ancestors : Array(Crystal::ASTNode),
        exits : Terminator,
      ) : Array(Step)
        flow = new(name, exits)
        (0...ancestors.size - 1).each do |index|
          flow.between(ancestors[index], ancestors[index + 1], ancestors[0..index])
        end
        flow.steps
      end

      def initialize(@name : String, @exits : Terminator) : Nil
        @steps = Array(Step).new
        @prefix = Array(Crystal::ASTNode).new
      end

      def between(
        parent : Crystal::ASTNode,
        child : Crystal::ASTNode,
        prefix : Array(Crystal::ASTNode),
      ) : Nil
        @prefix = prefix
        case parent
        in Crystal::If
          condition(parent.cond, true) if parent.then.same?(child)
          condition(parent.cond, false) if parent.else.same?(child)
        in Crystal::Unless
          condition(parent.cond, false) if parent.then.same?(child)
          condition(parent.cond, true) if parent.else.same?(child)
        in Crystal::While
          condition(parent.cond, true) if parent.body.same?(child)
        in Crystal::Until
          condition(parent.cond, false) if parent.body.same?(child)
        in Crystal::And
          condition(parent.left, true) if parent.right.same?(child)
        in Crystal::Or
          condition(parent.left, false) if parent.right.same?(child)
        in Crystal::Case
          case_branch(parent, child)
        in Crystal::Expressions
          sequence(parent.expressions, child)
        in Crystal::When, Crystal::ASTNode
          nil
        end
      end

      def collect(cond : Crystal::ASTNode, positive : Bool, prefix : Array(Crystal::ASTNode)) : Nil
        @prefix = prefix
        condition(cond, positive)
      end

      def walk(body : Crystal::ASTNode, prefix : Array(Crystal::ASTNode)) : Nil
        @prefix = prefix
        statements = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        statements.each { |statement| guard(statement) }
      end

      def exits?(node : Crystal::ASTNode?) : Bool
        case node
        in Crystal::Return, Crystal::Break, Crystal::Next then true
        in Crystal::Call                                  then @exits.terminates?(node)
        in Crystal::Expressions
          node.expressions.last?.try { |last| exits?(last) } || false
        in Crystal::ASTNode, Nil then false
        end
      end

      private def sequence(statements : Array(Crystal::ASTNode), child : Crystal::ASTNode) : Nil
        statements.each do |statement|
          break if statement.same?(child)

          guard(statement)
        end
      end

      private def guard(statement : Crystal::ASTNode) : Nil
        within = @prefix + [statement]
        outer = @prefix
        @prefix = within
        guarded(statement, within)
        @prefix = outer
      end

      private def guarded(statement : Crystal::ASTNode, within : Array(Crystal::ASTNode)) : Nil
        case statement
        in Crystal::Assign
          target = statement.target
          return unless target.is_a?(Crystal::Var) && target.name == @name

          @steps << Assigned.new(statement.value, within)
        in Crystal::OpAssign
          target = statement.target
          return unless target.is_a?(Crystal::Var) && target.name == @name && statement.op == "||"

          @steps << OrAssigned.new(statement.value, within)
        in Crystal::MultiAssign
          value = LocalAssignments.unpacked(statement, @name)
          @steps << Assigned.new(value, within) if value
        in Crystal::If
          branches = [Branch.new(true, statement.then), Branch.new(false, statement.else)]
          @steps << Branched.new(statement.cond, branches, within, assigns?(statement))
        in Crystal::Unless
          branches = [Branch.new(false, statement.then), Branch.new(true, statement.else)]
          @steps << Branched.new(statement.cond, branches, within, assigns?(statement))
        in Crystal::Or
          condition(statement.left, true) if exits?(statement.right)
        in Crystal::Case
          case_exits(statement)
        in Crystal::While
          nested(statement)
          condition(statement.cond, false)
        in Crystal::Until
          nested(statement)
          condition(statement.cond, true)
        in Crystal::ASTNode
          nested(statement)
        end
      end

      private def case_exits(statement : Crystal::Case) : Nil
        subject = unwrapped(statement.cond)
        if subject.is_a?(Crystal::Assign) && (target = subject.target).is_a?(Crystal::Var)
          return nested(statement) unless target.name == @name

          @steps << Assigned.new(subject.value, @prefix + [statement])
        elsif !(subject.is_a?(Crystal::Var) && subject.name == @name)
          return nested(statement)
        end

        excluded = Array(Crystal::ASTNode).new
        statement.whens.each do |branch|
          next unless exits?(branch.body)

          types = type_conditions(branch.conds)
          return unless types

          excluded.concat(types)
        end
        @steps << IsA.new(excluded, false) unless excluded.empty?
      end

      private def unwrapped(node : Crystal::ASTNode?) : Crystal::ASTNode?
        return node.expressions[0] if node.is_a?(Crystal::Expressions) && node.expressions.size == 1

        node
      end

      private def assigns?(statement : Crystal::ASTNode) : Bool
        !LocalAssignments.find(statement, @name).empty?
      end

      private def nested(statement : Crystal::ASTNode) : Nil
        values = LocalAssignments.locate(statement, @name)
        @steps << Reassigned.new(values, @prefix + [statement]) unless values.empty?
      end

      private def case_branch(parent : Crystal::Case, child : Crystal::ASTNode) : Nil
        subject = unwrapped(parent.cond)
        if subject.is_a?(Crystal::Assign) && (target = subject.target).is_a?(Crystal::Var)
          return unless target.name == @name

          @steps << Assigned.new(subject.value, @prefix.dup)
        elsif !(subject.is_a?(Crystal::Var) && subject.name == @name)
          return
        end

        if (taken = parent.whens.find(&.same?(child)))
          earlier = Array(Crystal::ASTNode).new
          parent.whens.each do |branch|
            break if branch.same?(taken)

            type_conditions(branch.conds).try { |types| earlier.concat(types) }
          end
          @steps << IsA.new(earlier, false) unless earlier.empty?
          types = type_conditions(taken.conds)
          @steps << IsA.new(types, true) if types
        elsif parent.else.same?(child)
          all = Array(Crystal::ASTNode).new
          parent.whens.each do |branch|
            types = type_conditions(branch.conds)
            return unless types

            all.concat(types)
          end
          @steps << IsA.new(all, false)
        end
      end

      private def type_conditions(conds : Array(Crystal::ASTNode)) : Array(Crystal::ASTNode)?
        types = Array(Crystal::ASTNode).new(conds.size)
        conds.each do |cond|
          case cond
          in Crystal::Path, Crystal::Generic then types << cond
          in Crystal::NilLiteral
            types << Crystal::Path.global(CoreType::Nil.type_name)
          in Crystal::ASTNode then return
          end
        end
        types
      end

      private def condition(cond : Crystal::ASTNode, positive : Bool) : Nil
        case cond
        in Crystal::Var
          @steps << Truthy.new(positive) if cond.name == @name
        in Crystal::IsA
          obj = unwrapped(cond.obj)
          if obj.is_a?(Crystal::Assign) && (target = obj.target).is_a?(Crystal::Var)
            return unless target.name == @name

            @steps << Assigned.new(obj.value, @prefix + [cond])
            @steps << IsA.new([cond.const], positive)
          elsif obj.is_a?(Crystal::Var) && obj.name == @name
            @steps << IsA.new([cond.const], positive)
          end
        in Crystal::Not
          inside(cond) { condition(cond.exp, !positive) }
        in Crystal::And
          return unless positive

          inside(cond) do
            condition(cond.left, true)
            condition(cond.right, true)
          end
        in Crystal::Or
          return either_is_a(cond) if positive

          inside(cond) do
            condition(cond.left, false)
            condition(cond.right, false)
          end
        in Crystal::Assign
          target = cond.target
          return unless target.is_a?(Crystal::Var) && target.name == @name

          @steps << Assigned.new(cond.value, @prefix + [cond])
          @steps << Truthy.new(positive)
        in Crystal::Expressions
          return unless cond.expressions.size == 1

          inside(cond) { condition(cond.expressions[0], positive) }
        in Crystal::ASTNode then nil
        end
      end

      private def inside(node : Crystal::ASTNode, & : ->) : Nil
        @prefix << node
        yield
        @prefix.pop
      end

      private def either_is_a(cond : Crystal::Or) : Nil
        left = Flow.new(@name, @exits)
        right = Flow.new(@name, @exits)
        left.collect(cond.left, true, @prefix)
        right.collect(cond.right, true, @prefix)
        first = left.steps[0]?
        second = right.steps[0]?
        return unless left.steps.size == 1 && right.steps.size == 1
        return unless first.is_a?(IsA) && second.is_a?(IsA) && first.positive && second.positive

        @steps << IsA.new(first.types + second.types, true)
      end

      private def empty?(node : Crystal::ASTNode?) : Bool
        node.nil? || node.is_a?(Crystal::Nop)
      end
    end
  end
end
