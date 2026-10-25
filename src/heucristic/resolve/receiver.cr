require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/shims"
require "../index/evident"
require "../index/macro_call"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./methods"
require "./precision"
require "./unify"
require "./render"
require "./local_declarations"
require "./body_facts"
require "./local_assignments"
require "./variable_references"
require "./rescue_variables"
require "./flow"
require "./call_exits"
require "./breaks"
require "../syntax/yield_sites"

require "../syntax/well_known"

module Heucristic
  module Resolve
    class Receiver
      DEPTH_LIMIT = 48

      record Unscoped

      record Site,
        block : Crystal::Block?,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(String),
        named : Array(Binding) = Array(Binding).new,
        block_arg : Crystal::ASTNode? = nil do
        NONE = new(
          nil,
          Syntax::Context.new(Array(String).new, Array(String).new, nil),
          Array(Binding).new,
          Array(String).new,
        )
      end

      FALSEY = {CoreType::Nil, CoreType::Bool, CoreType::Pointer}

      def initialize(
        @workspace : Index::Workspace,
        @shims : Index::Shims,
        @types : Types,
        @methods : Methods,
      ) : Nil
        @depth = 0
        @exit_answers = Hash(String, Hash(UInt64, Bool)).new
        @facts = Hash(UInt64, BodyFacts).new
        @typed_values = Hash(UInt64, Resolution).new
        @block_inputs = Hash({UInt64, Int32}, Resolution).new
        @yield_scopes = Hash(UInt64, Resolution | Unscoped).new
      end

      def result_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Resolution
        return TypeRef.of(:bool) if chained_comparison?(call)

        receiver = of_call(call, context, locals, visiting)
        return receiver if receiver.is_a?(Unknown)
        if receiver.is_a?(TypeRef) && receiver.is?(:tuple)
          element = tuple_element_at(receiver, call)
          return element if element
        end
        if receiver.is_a?(TypeRef) && receiver.labelled?
          element = labelled_element_at(receiver, call)
          return element if element
        end

        shape = shape_of(call, context, locals, visiting)
        site = Site.new(
          call.block, context, locals, visiting, shape.named_arguments, call.block_arg
        )
        if call.obj.nil? && Syntax::WellKnown::Super.named?(call.name)
          return super_result(call, receiver, shape, site)
        end

        outcome = result_of(receiver, shape, site)
        return macro_result(call, context, outcome) if outcome.is_a?(Unknown)

        block = call.block
        return outcome if block.nil?

        escaped = break_values(block, site)
        escaped.empty? ? outcome : union([outcome] + escaped)
      end

      def shape_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Methods::Call
        arguments = Array(Resolution).new(call.args.size)
        call.args.each { |argument| arguments << type_of(argument, context, visiting, locals) }
        named = call.named_args.try(&.map(&.name)) || Array(String).new
        named_arguments = Array(Binding).new
        call.named_args.try &.each do |argument|
          value = type_of(argument.value, context, visiting, locals)
          named_arguments << Binding.new(argument.name, value)
        end
        Methods::Call.new(
          call.name,
          call.args.size,
          blocky?(call),
          arguments,
          named,
          named_arguments,
          call.obj.nil?,
          context.path,
          call.args.map { |argument| Precision.of(argument) },
        )
      end

      def result_of(receiver : Resolved, call : Methods::Call) : Resolution
        result_of(receiver, call, Site::NONE)
      end

      def result_of(receiver : Resolved, call : Methods::Call, site : Site) : Resolution
        if receiver.is_a?(UnionRef)
          members = receiver.members.map do |member|
            member.is_a?(Unknown) ? member : result_of(member, call, site)
          end
          return union(members)
        end

        if receiver.is_a?(TypeVar)
          return Unknown.new(
            :free_variable,
            "#{receiver} is a type variable; `#{call.name}` depends on its instantiation",
          )
        end
        return receiver if receiver.is_a?(TypeRef) && receiver.is?(:no_return)
        if receiver.is_a?(MetaRef) && call.name == "|"
          other = call.arguments[0]?
          return UnionRef.new([receiver, other] of Resolution) if other.is_a?(MetaRef)
        end

        defs = @methods.lookup(receiver, call)
        if defs.empty? && receiver.is_a?(MetaRef) && (variable = receiver.of).is_a?(TypeVar)
          return Unknown.new(
            :free_variable,
            "#{variable} is a type variable; `#{call.name}` depends on its instantiation",
          )
        end
        return virtual_result(receiver, call, site) if defs.empty?

        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << return_type(entry, receiver, call.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1
        if call.arguments.empty? && !call.block
          annotated = distinct.reject do |result|
            result.is_a?(Unknown) && result.reason.no_annotation?
          end
          return annotated[0] if annotated.size == 1
        end
        return union(results) if module?(receiver)

        Unknown.new(:ambiguous, "#{defs.size} overloads of `#{call.name}` do not agree on a type")
      end

      def of_call(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Resolution
        receiver = call.obj
        return implicit_receiver(call, context, locals, visiting) unless receiver

        type_of(receiver, context, visiting, locals)
      end

      def yield_scope(context : Syntax::Context) : Resolution | Unscoped
        context.blocks.reverse_each do |block_call|
          next if opaque_block?(block_call)

          scope = @yield_scopes[block_call.object_id]? || begin
            computed = block_scope(block_call, context)
            if computed.is_a?(Unscoped) || !unsettled?(computed)
              @yield_scopes[block_call.object_id] = computed
            end
            computed
          end
          return scope unless scope.is_a?(Unscoped)
        end
        Unscoped.new
      end

      def variable(name : String, context : Syntax::Context) : Resolution
        variable(name, context, Array(String).new, Array(Binding).new)
      end

      def instance_var(name : String, context : Syntax::Context) : Resolution
        instance_var(name, context, Array(String).new)
      end

      def return_type(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution) = Array(Resolution).new,
        site : Site = Site::NONE,
      ) : Resolution
        receiver = owning(entry, receiver)
        if Syntax::WellKnown::Initialize.named?(entry.name) && receiver.is_a?(MetaRef)
          return receiver.of
        end
        if Syntax::WellKnown::New.named?(entry.name) && receiver.is_a?(MetaRef)
          proc_class = receiver.of.is_a?(TypeRef) && receiver.of.as(TypeRef).is?(:proc)
          if entry.return_type.is_a?(Index::Unrestricted) && (site.block.nil? || proc_class)
            return receiver.of
          end
        end
        if entry.qualified == "Object#class"
          return MetaRef.new(receiver) if receiver.is_a?(TypeRef)
          return receiver if receiver.is_a?(MetaRef)
        end
        if entry.qualified == "Enum#value" && receiver.is_a?(TypeRef)
          return enum_base(receiver)
        end
        if entry.qualified == "Array#compact" && receiver.is_a?(TypeRef)
          return compacted(receiver)
        end
        if entry.qualified == "Proc#call" && receiver.is_a?(TypeRef)
          return receiver.arguments.last? || Unknown.new(:unsupported, "a proc without a signature")
        end
        if receiver.is_a?(TypeRef) && receiver.is?(:tuple)
          special = tuple_special(entry, receiver, arguments, site)
          return special if special
        end
        if entry.qualified.in?("Enumerable#zip", "Enumerable#zip?") && !site.block
          return zipped(receiver, arguments, entry.name == "zip?")
        end
        if entry.qualified == "Enumerable#to_h" && !site.block && receiver.is_a?(TypeRef)
          return pairs_to_hash(receiver)
        end

        case (restriction = entry.return_type)
        in Index::Unrestricted
          shim = @shims.find(entry)
          return return_type(shim.entry, receiver, arguments, site) if shim
          if entry.name == "loop" && entry.owner.is_a?(Index::TopLevel) && (looped = site.block)
            return loop_result(looped, site)
          end
          if receiver.is_a?(TypeRef) && arguments.empty? && !site.block
            known = Syntax::WellKnown.from_name(entry.name)
            return receiver if known && known.copies?
          end
          if (target = entry.forwards_to)
            return forwarded(entry, target, arguments, site)
          end
          if (read = entry.reads)
            value = read_instance_var(entry, read.name, receiver, arguments, site)
            return read.asserted ? truthy(value, true) : value
          end

          Unknown.new(:no_annotation, "#{entry.qualified} has no return type restriction")
        in Syntax::TypeReader::Unsupported
          Unknown.new(:unsupported, restriction.source)
        in Syntax::Type
          scope = return_scope(entry, receiver, arguments, site)
          return scope if scope.is_a?(Unknown)

          @types.resolve(restriction, scope)
        end
      end

      def signature(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : String
        receiver = owning(entry, receiver)
        scope = return_scope(entry, receiver, arguments, site)
        return entry.signature if scope.is_a?(Unknown)

        parameters = entry.parameters.map do |parameter|
          restriction = parameter.restriction
          text = restriction.is_a?(Syntax::Type) ? Render.type(restriction, scope, @types) : nil
          parameter.rendered(text)
        end
        returning = return_type(entry, receiver, arguments, site)
        receiver_name = entry.receiver.metaclass? ? "self" : nil
        Index::Signature.render(receiver_name, entry.name, parameters) do |io|
          io << " : " << returning if returning.is_a?(Resolved)
        end
      end

      def invalidate : Nil
        @exit_answers.clear
        @facts.clear
        @typed_values.clear
        @block_inputs.clear
        @yield_scopes.clear
      end

      def forget(path : String) : Nil
        @exit_answers.delete(path)
        @facts.clear
        @typed_values.clear
        @block_inputs.clear
        @yield_scopes.clear
      end

      def remembered_exit(
        call : Crystal::Call,
        context : Syntax::Context,
        visiting : Array(String),
        & : Resolution -> Bool
      ) : Bool
        answers = exit_answers(call)
        cached = answers.try(&.[call.object_id]?)
        return cached unless cached.nil?

        receiver = of_call(call, context, Array(Binding).new, visiting)
        answer = yield receiver
        answers[call.object_id] = answer if answers && !unsettled?(receiver)
        answer
      end

      def no_return?(entry : Index::Def) : Bool
        no_return?(entry, Array(String).new)
      end

      private def no_return?(entry : Index::Def, visiting : Array(String)) : Bool
        restriction = entry.return_type
        if restriction.is_a?(Index::Unrestricted)
          shim = @shims.find(entry)
          restriction = shim.entry.return_type if shim
        end
        if restriction.is_a?(Syntax::Named) && restriction.names == [CoreType::NoReturn.type_name]
          return true
        end

        tail = entry.exit_call
        return false unless tail
        return true if KnownExits.new.terminates?(Crystal::Call.new(nil, tail))
        return false if visiting.includes?(entry.qualified)

        owner = entry.owner
        return false unless owner.is_a?(String)

        callees = @methods.named_on(TypeRef.new(owner, Array(Resolution).new), tail)
        deeper = visiting + [entry.qualified]
        !callees.empty? && callees.all? { |callee| no_return?(callee, deeper) }
      end

      def narrowing_steps(name : String, context : Syntax::Context) : Array(Flow::Step)
        exits = exits_for(context, Array(String).new)
        Flow.steps(name, context.ancestors, exits, facts_for(context))
      end

      def self.chained_comparison?(call : Crystal::Call) : Bool
        return false unless COMPARISONS.includes?(call.name)

        inner = call.obj
        inner.is_a?(Crystal::Call) && COMPARISONS.includes?(inner.name) && inner.args.size == 1
      end

      def typed(node : Crystal::ASTNode, context : Syntax::Context) : Resolution
        type_of(node, context, Array(String).new, Array(Binding).new)
      end

      def type_of(entry : Index::Constant) : Resolution
        constant_type(entry, entry.name, Array(String).new)
      end

      private def case_subject(
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        enclosing = context.ancestors.reverse_each.find { |node| node.is_a?(Crystal::Case) }
        subject = enclosing.is_a?(Crystal::Case) ? enclosing.cond : nil
        unless subject
          return Unknown.new(:unsupported, "an implicit object outside a case")
        end
        if subject.is_a?(Crystal::Expressions) && subject.expressions.size == 1
          subject = subject.expressions[0]
        end

        type_of(subject, context, visiting, locals)
      end

      private def super_result(
        call : Crystal::Call,
        receiver : Resolved,
        shape : Methods::Call,
        site : Site,
      ) : Resolution
        definition = site.context.def_node
        owner = site.context.owner
        unless definition && owner.is_a?(String)
          return Unknown.new(:no_annotation, "super outside a method")
        end

        return TypeRef.of(:nil) if Syntax::WellKnown::Initialize.named?(definition.name)

        arity = call.has_parentheses? ? shape.arity : definition.args.size
        parent_call = Methods::Call.new(
          definition.name, arity, shape.block, shape.arguments, shape.named
        )
        defs = @methods.lookup_super(receiver, owner, parent_call)
        if defs.empty?
          return Unknown.new(:unresolved_name, "no `#{definition.name}` above #{owner}")
        end

        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << return_type(entry, receiver, shape.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1

        Unknown.new(:ambiguous, "#{defs.size} overloads of `super` do not agree on a type")
      end

      private def macro_result(
        call : Crystal::Call,
        context : Syntax::Context,
        outcome : Unknown,
      ) : Unknown
        return outcome unless outcome.reason.unresolved_name?
        if Index::MacroCall.like?(call, @workspace)
          return Unknown.new(:macro, "`#{call.name}` is a macro; its expansion is not typed")
        end
        return outcome unless call.obj.nil?

        owner = Index::MacroCall.enclosing(context.ancestors, @workspace)
        return outcome unless owner

        detail = "`#{call.name}` sits inside the `#{owner.name}` macro, which decides what it means"
        Unknown.new(:macro, detail)
      end

      private def blocky?(call : Crystal::Call) : Bool
        !call.block.nil? || !call.block_arg.nil?
      end

      private def instance_var(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        owner = context.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end

        levels = [owner]
        chain = @types.ancestors(owner)
        levels.concat(chain) unless chain.is_a?(Unknown)
        levels.each do |level|
          entries = @workspace.instance_vars_of(level).select(&.name.==(name))
          next if entries.empty?

          scope = ivar_scope(owner, level)
          return scope if scope.is_a?(Unknown)

          return instance_var_from(entries, level, scope, visiting + [name])
        end

        from_includers = includers_instance_var(name, owner, visiting)
        return from_includers if from_includers

        Unknown.new(
          :no_annotation, "#{name} is never declared or assigned an evident type in #{owner}"
        )
      end

      private def instance_var_from(
        entries : Array(Index::InstanceVar),
        level : String,
        scope : Scope,
        visiting : Array(String),
      ) : Resolution
        declared = entries.select(&.origin.declared?)
        unless declared.empty?
          typed = Array(Resolution).new(declared.size)
          declared.each { |entry| typed << declared(entry.type, scope) }
          return union(typed)
        end

        typed = Array(Resolution).new(entries.size)
        entries.each do |entry|
          type = entry.type
          if type.is_a?(Syntax::Type)
            typed << declared(type, scope)
            next
          end

          expression = entry.expression
          next unless expression && guessable?(expression)

          context = Syntax::Context.new(
            [level], @types.type_vars_of(level), entry.definition, entry.path
          )
          guessed = type_of(expression, context, visiting, Array(Binding).new)
          typed << guessed unless guessed.is_a?(Unknown)
        end
        return union(typed) unless typed.empty?

        assigned = entries.map(&.type).select(Syntax::TypeReader::Unsupported).map(&.source)
        Unknown.new(
          :no_annotation,
          "#{entries[0].name} is only assigned #{assigned.join(", ")}; declare its type",
        )
      end

      private def guessable?(expression : Crystal::ASTNode) : Bool
        case expression
        in Crystal::Var, Crystal::Path then true
        in Crystal::Call               then expression.obj.is_a?(Crystal::Path)
        in Crystal::ASTNode            then false
        end
      end

      private def case_value(
        node : Crystal::Case,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        branches = Array(Resolution).new(node.whens.size + 1)
        node.whens.each do |branch|
          inner = context.inside(node, branch).inside(branch.body)
          branches << type_of(branch.body, inner, visiting, locals)
        end
        otherwise = node.else
        if otherwise
          branches << type_of(otherwise, context.inside(node, otherwise), visiting, locals)
        elsif !node.exhaustive?
          branches << TypeRef.of(:nil)
        end
        union(branches)
      end

      private def select_value(
        node : Crystal::Select,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        branches = Array(Resolution).new(node.whens.size + 1)
        node.whens.each do |branch|
          inner = context.inside(node, branch).inside(branch.body)
          branches << type_of(branch.body, inner, visiting, locals)
        end
        if (otherwise = node.else)
          branches << type_of(otherwise, context.inside(node, otherwise), visiting, locals)
        end
        union(branches)
      end

      private def rescued_value(
        node : Crystal::ExceptionHandler,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        branches = Array(Resolution).new
        normal = node.else || node.body
        branches << type_of(normal, context.inside(node, normal), visiting, locals)
        node.rescues.try &.each do |handler|
          inner = context.inside(node, handler).inside(handler.body)
          branches << type_of(handler.body, inner, visiting, locals)
        end
        union(branches)
      end

      private def op_assigned(
        node : Crystal::OpAssign,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        current = type_of(node.target, context, visiting, locals)
        value = type_of(node.value, context, visiting, locals)
        if node.op == "||"
          present = truthy(current, true)
          return value if present.is_a?(TypeRef) && present.is?(:nil)

          return union([present, value] of Resolution)
        end
        return union([truthy(current, false), value] of Resolution) if node.op == "&&"
        return current if current.is_a?(Unknown)

        result_of(current, Methods::Call.new(node.op, 1, false, [value] of Resolution))
      end

      private def hash_literal(
        node : Crystal::HashLiteral,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        if node.entries.empty?
          return Unknown.new(:no_annotation, "an empty hash literal needs `of K => V`")
        end

        keys = Array(Resolution).new(node.entries.size)
        values = Array(Resolution).new(node.entries.size)
        node.entries.each do |entry|
          keys << type_of(entry.key, context, visiting, locals)
          values << type_of(entry.value, context, visiting, locals)
        end
        key = union(keys)
        return key if key.is_a?(Unknown)
        value = union(values)
        return value if value.is_a?(Unknown)

        TypeRef.of(:hash, [key, value] of Resolution)
      end

      private def yielded_result(context : Syntax::Context) : Resolution
        definition = context.def_node
        return Unknown.new(:no_annotation, "yield outside any method") unless definition

        block_arg = definition.block_arg
        restriction = block_arg.try(&.restriction)
        output = restriction.is_a?(Crystal::ProcNotation) ? restriction.output : nil
        unless output
          return Unknown.new(
            :no_annotation, "the block of #{definition.name} has no declared result type"
          )
        end

        declared(Syntax::TypeReader.read(output), scope(context))
      end

      COMPARISONS = {"<", "<=", ">", ">="}

      private def chained_comparison?(call : Crystal::Call) : Bool
        Receiver.chained_comparison?(call)
      end

      private def exits_for(context : Syntax::Context, visiting : Array(String)) : CallExits
        CallExits.new(@methods, implicit_self(context), self, context, visiting)
      end

      private def virtual_result(
        receiver : Resolved,
        call : Methods::Call,
        site : Site,
      ) : Resolution
        missing = Unknown.new(:unresolved_name, "no `#{call.name}` on #{receiver}")
        return missing unless receiver.is_a?(TypeRef) && receiver.arguments.empty?
        return missing unless @methods.abstract_class?(receiver.name)

        concrete = @methods.concrete_descendants(receiver.name)
        return missing if concrete.empty?

        results = Array(Resolution).new(concrete.size)
        concrete.each do |descendant|
          below = TypeRef.new(descendant, Array(Resolution).new)
          if @methods.lookup(below, call).empty?
            return Unknown.new(
              :unresolved_name, "no `#{call.name}` on #{descendant}, a subclass of #{receiver}"
            )
          end
          results << result_of(below, call, site)
        end
        union(results)
      end

      private def exit_answers(call : Crystal::Call) : Hash(UInt64, Bool)?
        filename = call.location.try(&.filename)
        return unless filename.is_a?(String)

        @exit_answers[filename] ||= Hash(UInt64, Bool).new
      end

      private def module?(receiver : Resolved) : Bool
        receiver.is_a?(TypeRef) && @workspace.namespaces(receiver.name).any?(Index::ModuleNamespace)
      end

      private def owning(entry : Index::Def, receiver : Resolved) : Resolved
        owner = entry.owner
        return receiver unless owner.is_a?(String) && receiver.is_a?(TypeRef)
        return receiver if receiver.name == owner || module?(receiver)

        chain = @types.ancestors(receiver.name)
        return receiver if chain.is_a?(Array(String)) && chain.includes?(owner)

        TypeRef.new(owner, Array(Resolution).new)
      end

      private def labelled_element_at(receiver : TypeRef, call : Crystal::Call) : Resolution?
        return unless call.name.in?("[]", "[]?") && call.args.size == 1

        key = call.args[0]
        return unless key.is_a?(Crystal::SymbolLiteral)

        index = receiver.labels.index(key.value)
        member = index ? receiver.arguments[index]? : nil
        if call.name == "[]?"
          nil_type = TypeRef.of(:nil)
          return member ? union([member, nil_type] of Resolution) : nil_type
        end

        member || Unknown.new(:unresolved_name, "no key #{key.value.inspect} in #{receiver}")
      end

      private def tuple_element_at(receiver : TypeRef, call : Crystal::Call) : Resolution?
        return unless call.name.in?("[]", "[]?") && call.args.size == 1

        literal = call.args[0]
        return unless literal.is_a?(Crystal::NumberLiteral)

        index = literal.value.to_i?
        return unless index

        member = receiver.arguments[index]?
        if call.name == "[]?"
          nil_type = TypeRef.of(:nil)
          return member ? union([member, nil_type] of Resolution) : nil_type
        end

        member || Unknown.new(:unresolved_name, "#{receiver} has no element #{index}")
      end

      private def tuple_special(
        entry : Index::Def,
        receiver : TypeRef,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution?
        members = receiver.arguments
        qualified = entry.qualified
        if qualified == "Tuple#first" || qualified == "Tuple#last"
          member = entry.name == "first" ? members.first? : members.last?
          return member || Unknown.new(:no_annotation, "#{receiver} has no elements")
        end
        if qualified == "Tuple#first?" || qualified == "Tuple#last?"
          member = entry.name == "first?" ? members.first? : members.last?
          return unless member

          return union([member, TypeRef.of(:nil)] of Resolution)
        end
        return unless qualified == "Tuple#map"

        scope = return_scope(entry, receiver, arguments, site)
        return scope if scope.is_a?(Unknown)

        mapped = scope.bound("U")
        return unless mapped

        TypeRef.of(:tuple, Array(Resolution).new(members.size, mapped))
      end

      private def zipped(
        receiver : Resolved,
        arguments : Array(Resolution),
        nilable : Bool,
      ) : Resolution
        return Unknown.new(:unsupported, "zip on #{receiver}") unless receiver.is_a?(TypeRef)

        element = element_of(receiver)
        return element if element.is_a?(Unknown)

        members = Array(Resolution).new(arguments.size + 1)
        members << element
        arguments.each do |argument|
          return argument if argument.is_a?(Unknown)
          return Unknown.new(:unsupported, "zip with #{argument}") unless argument.is_a?(TypeRef)

          other = element_of(argument)
          return other if other.is_a?(Unknown)

          nil_type = TypeRef.of(:nil)
          members << (nilable ? union([other, nil_type] of Resolution) : other)
        end
        TypeRef.of(:array, [TypeRef.of(:tuple, members)] of Resolution)
      end

      private def pairs_to_hash(receiver : TypeRef) : Resolution
        element = element_of(receiver)
        return element if element.is_a?(Unknown)
        unless element.is_a?(TypeRef) && element.is?(:tuple) && element.arguments.size == 2
          return Unknown.new(:no_annotation, "to_h needs elements typed as two-element tuples")
        end

        TypeRef.of(:hash, element.arguments)
      end

      private def element_of(collection : TypeRef) : Resolution
        bindings = @types.bindings(collection, CoreType::Enumerable.type_name)
        return bindings if bindings.is_a?(Unknown)

        bindings.find(&.name.==("T")).try(&.value) ||
          Unknown.new(:no_annotation, "#{collection} does not state its element type")
      end

      private def includers_instance_var(
        name : String,
        owner : String,
        visiting : Array(String),
      ) : Resolution?
        return unless @workspace.namespaces(owner).any?(Index::ModuleNamespace)
        return if visiting.includes?(owner)

        found = Array(Resolution).new
        @workspace.each_mixin do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)
          includer = mixin.owner
          next unless includer.is_a?(String)

          resolved = @types.resolve_lexically(target, Scope.of(includer))
          next unless resolved.is_a?(TypeRef) && resolved.name == owner

          context = Syntax::Context.new([includer], Array(String).new, nil)
          resolution = instance_var(name, context, visiting + [owner])
          found << resolution unless resolution.is_a?(Unknown)
        end
        return if found.empty?

        union(found)
      end

      private def ivar_scope(owner : String, level : String) : Scope | Unknown
        return Scope.new(owner, @types.type_vars_of(owner)) if level == owner

        this = TypeRef.new(owner, Array(Resolution).new)
        bindings = @types.bindings(this, level)
        return bindings if bindings.is_a?(Unknown)

        Scope.new(level, @types.type_vars_of(level), bindings)
      end

      private def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        if @depth >= DEPTH_LIMIT
          return Unknown.new(:too_deep, "typing `#{node}` needs more than #{DEPTH_LIMIT} steps")
        end

        @depth += 1
        begin
          typed(node, context, visiting, locals)
        ensure
          @depth -= 1
        end
      end

      private def typed(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        return constant(node, context, visiting) if node.is_a?(Crystal::Path)
        evident = Index::Evident.type(node)
        return declared(evident, scope(context)) if evident.is_a?(Syntax::Type)

        case node
        in Crystal::Var then variable(node.name, context, visiting, locals)
        in Crystal::InstanceVar, Crystal::ClassVar
          instance_var(node.name, context, visiting)
        in Crystal::Call        then result_of(node, context, locals, visiting)
        in Crystal::Path        then constant(node, context, visiting)
        in Crystal::ImplicitObj then case_subject(context, visiting, locals)
        in Crystal::If, Crystal::Unless
          branches = Array(Resolution).new(2)
          branches << type_of(node.then, context.inside(node, node.then), visiting, locals)
          branches << type_of(node.else, context.inside(node, node.else), visiting, locals)
          union(branches)
        in Crystal::Return, Crystal::Break, Crystal::Next
          TypeRef.of(:no_return)
        in Crystal::Case             then case_value(node, context, visiting, locals)
        in Crystal::Select           then select_value(node, context, visiting, locals)
        in Crystal::ExceptionHandler then rescued_value(node, context, visiting, locals)
        in Crystal::Assign           then type_of(node.value, context, visiting, locals)
        in Crystal::OpAssign         then op_assigned(node, context, visiting, locals)
        in Crystal::Yield            then yielded_result(context)
        in Crystal::SizeOf, Crystal::InstanceSizeOf, Crystal::AlignOf, Crystal::InstanceAlignOf
          TypeRef.of(:int32)
        in Crystal::RangeLiteral
          bounds = Array(Resolution).new(2)
          bounds << type_of(node.from, context, visiting, locals)
          bounds << type_of(node.to, context, visiting, locals)
          bounds.find(&.is_a?(Unknown)) || TypeRef.of(:range, bounds)
        in Crystal::Or
          left = type_of(node.left, context.inside(node, node.left), visiting, locals)
          right = type_of(node.right, context.inside(node, node.right), visiting, locals)
          union([truthy(left, true), right] of Resolution)
        in Crystal::And
          left = type_of(node.left, context.inside(node, node.left), visiting, locals)
          right = type_of(node.right, context.inside(node, node.right), visiting, locals)
          union([truthy(left, false), right] of Resolution)
        in Crystal::ArrayLiteral
          collection = literal_collection(node, context)
          elements(node.elements, context, visiting, locals) do |inner|
            TypeRef.new(collection, [inner] of Resolution)
          end
        in Crystal::HashLiteral then hash_literal(node, context, visiting, locals)
        in Crystal::TupleLiteral
          members = Array(Resolution).new(node.elements.size)
          node.elements.each { |element| members << type_of(element, context, visiting, locals) }
          members.find(&.is_a?(Unknown)) || TypeRef.of(:tuple, members)
        in Crystal::NamedTupleLiteral
          members = Array(Resolution).new(node.entries.size)
          node.entries.each { |entry| members << type_of(entry.value, context, visiting, locals) }
          unknown = members.find(&.is_a?(Unknown))
          unknown || TypeRef.new(CoreType::NamedTuple.type_name, members, node.entries.map(&.key))
        in Crystal::Nop then TypeRef.of(:nil)
        in Crystal::Expressions
          last = node.expressions.last?
          return TypeRef.of(:nil) unless last

          type_of(last, context.inside(node, last), visiting, locals)
        in Crystal::ASTNode
          Unknown.new(:inference_needed, "the type of `#{node}` is not written in the source")
        end
      end

      private def variable(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        return implicit_self(context) if Syntax::WellKnown::SelfName.named?(name)
        key = variable_key(name, context)
        exits = exits_for(context, visiting + [key])
        facts = facts_for(context)
        steps = Flow.steps(name, context.ancestors, exits, facts)
        if (local = locals.find(&.name.==(name)))
          uncarried = steps.reject { |step| step.is_a?(Flow::Reassigned) && step.carried }
          return narrow(local.value, name, uncarried, context, visiting, locals)
        end
        return Unknown.new(:cycle, name) if visiting.includes?(key)

        if (captured = captured(name, context, visiting, locals))
          return captured
        end

        if (inner = shadowing_block(name, context))
          from_block = block_parameter(name, context, locals, visiting + [key])
          if from_block
            inner_steps = Flow.steps(name, context.ancestors[inner..], exits, facts)
            return narrow(from_block, name, inner_steps, context, visiting, locals)
          end
        end
        if (handler = enclosing_rescue(name, context))
          inner_steps = Flow.steps(name, context.ancestors[handler..], exits, facts)
          rescued = context.ancestors[handler].as(Crystal::Rescue)
          bound = rescued_type(rescued, context)
          return narrow(bound, name, inner_steps, context, visiting, locals)
        end

        base = declared_variable(name, context, visiting, locals, steps)
        narrow(base, name, steps, context, visiting, locals)
      end

      private def captured(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution?
        index = context.proc_index
        definition = context.def_node
        return unless index && definition
        return if definition.args.any?(&.name.==(name))
        return if shadowing_block(name, context).try(&.> index)

        inner = facts_of(definition.body)
        return unless inner.assigned(name).empty? && inner.declaration(name).nil?
        return if inner.rescued(name)

        outer = context.outside_proc(index)
        if reassigned_after?(name, context.ancestors[index], outer)
          return Unknown.new(
            :inference_needed, "#{name} is captured by a proc and reassigned after it"
          )
        end

        variable(name, outer, visiting, locals)
      end

      private def reassigned_after?(
        name : String,
        literal : Crystal::ASTNode,
        outer : Syntax::Context,
      ) : Bool
        created = literal.location
        facts = facts_for(outer)
        return false unless created && facts

        facts.assigned(name).any? do |assignment|
          at = assignment.location
          at && {at.line_number, at.column_number} > {created.line_number, created.column_number}
        end
      end

      private def facts_of(body : Crystal::ASTNode) : BodyFacts
        @facts[body.object_id] ||= BodyFacts.of(body)
      end

      private def facts_for(context : Syntax::Context) : BodyFacts?
        definition = context.def_node
        body = definition ? definition.body : context.ancestors.first?
        body ? facts_of(body) : nil
      end

      private def shadowing_block(name : String, context : Syntax::Context) : Int32?
        context.ancestors.rindex do |node|
          node.is_a?(Crystal::Block) && node.args.any?(&.name.==(name))
        end
      end

      private def narrow(
        base : Resolution,
        name : String,
        steps : Array(Flow::Step),
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        key = variable_key(name, context)
        steps.reduce(base) do |current, step|
          case step
          in Flow::Assigned
            at = context.at(step.within)
            typed = value_type(step.value, locals) ||
                    remember_value(
                      step.value,
                      type_of(step.value, at, visiting + [key], seeded(locals, name, current)),
                      locals,
                    )
            settled(name, current, step.value, typed)
          in Flow::Branched then branched(current, step, name, context, visiting, locals)
          in Flow::Reassigned
            values = Array(Resolution).new(step.values.size + 1)
            values << current unless step.definite
            seeded_locals = seeded(locals, name, current)
            step.values.each do |item|
              at = context.at(step.within + item.path)
              typed = value_type(item.value, locals) ||
                      remember_value(
                        item.value, type_of(item.value, at, visiting + [key], seeded_locals), locals
                      )
              values << settled(name, current, item.value, typed)
            end
            union(values)
          in Flow::OrAssigned
            at = context.at(step.within)
            typed = value_type(step.value, locals) ||
                    remember_value(
                      step.value,
                      type_of(step.value, at, visiting + [key], seeded(locals, name, current)),
                      locals,
                    )
            value = settled(name, current, step.value, typed)
            present = truthy(current, true)
            if present.is_a?(TypeRef) && present.is?(:nil)
              value
            else
              union([present, value] of Resolution)
            end
          in Flow::Truthy   then truthy(current, step.positive)
          in Flow::IsA      then narrow_is_a(current, step.types, step.positive, context)
          in Flow::Declared then declared(Syntax::TypeReader.read(step.restriction), scope(context))
          end
        end
      end

      private def truthy(current : Resolution, positive : Bool) : Resolution
        return current if current.is_a?(Unknown)

        members = current.is_a?(UnionRef) ? current.members : [current] of Resolution
        kept = members.select do |member|
          next true if member.is_a?(Unknown)
          falsey = member.is_a?(TypeRef) && FALSEY.any? { |core| member.is?(core) }
          positive ? !(member.is_a?(TypeRef) && member.is?(:nil)) : falsey
        end
        return TypeRef.of(:no_return) if kept.empty?

        kept.uniq!
        kept.size == 1 ? kept[0] : UnionRef.new(kept)
      end

      private def narrow_is_a(
        current : Resolution,
        types : Array(Crystal::ASTNode),
        positive : Bool,
        context : Syntax::Context,
      ) : Resolution
        targets = Array(TypeRef).new
        types.each do |type|
          resolved = declared(Syntax::TypeReader.read(type), scope(context))
          case resolved
          in TypeRef then targets << resolved
          in UnionRef
            resolved.members.each do |member|
              return current unless member.is_a?(TypeRef)

              targets << member
            end
          in MetaRef, TypeVar, Unknown then return current
          end
        end

        if current.is_a?(Unknown) || current.is_a?(TypeVar)
          return current unless positive
          return targets[0] if targets.size == 1

          widened = Array(Resolution).new(targets.size)
          targets.each { |target| widened << target }
          return UnionRef.new(widened)
        end

        members = current.is_a?(UnionRef) ? current.members : [current] of Resolution
        kept = Array(Resolution).new
        members.each do |member|
          unless member.is_a?(TypeRef)
            kept << member
            next
          end
          matched = targets.any? { |target| covers?(target, member) }
          if positive
            kept << member if matched
            targets.each { |target| kept << target if !matched && covers?(member, target) }
          else
            kept << member unless matched
          end
        end
        return TypeRef.of(:no_return) if kept.empty?

        kept.uniq!
        kept.size == 1 ? kept[0] : UnionRef.new(kept)
      end

      private def covers?(ancestor : TypeRef, descendant : TypeRef) : Bool
        return true if ancestor.name == descendant.name

        chain = @types.ancestors(descendant.name)
        !chain.is_a?(Unknown) && chain.includes?(ancestor.name)
      end

      private def assigning?(step : Flow::Step) : Bool
        case step
        in Flow::Assigned, Flow::Reassigned, Flow::OrAssigned, Flow::Declared then true
        in Flow::Branched                                                     then step.assigns
        in Flow::Truthy, Flow::IsA                                            then false
        end
      end

      private def variable_key(name : String, context : Syntax::Context) : String
        owner = context.blocks.last? || context.def_node
        owner ? "#{name}@#{owner.object_id}" : name
      end

      private def declared_variable(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
        steps : Array(Flow::Step),
      ) : Resolution
        definition = context.def_node
        body = definition ? definition.body : context.ancestors.first?
        unless body
          return Unknown.new(:no_annotation, "#{name} is outside any method or script")
        end

        facts = facts_of(body)
        rescued = facts.rescued(name)
        if rescued && context.ancestors.any?(&.same?(rescued))
          return rescued_type(rescued, context)
        end

        if definition && (parameter = definition.args.find(&.name.==(name)))
          restriction = parameter.restriction
          unless restriction
            return Unknown.new(:no_annotation, "parameter #{name} has no type restriction")
          end
          typed = declared(Syntax::TypeReader.read(restriction), scope(context))
          return typed if typed.is_a?(Unknown)
          return typed unless definition.splat_index == definition.args.index(parameter)

          return TypeRef.of(:tuple, [typed] of Resolution)
        end

        if definition && (block_arg = definition.block_arg) && block_arg.name == name
          restriction = block_arg.restriction
          unless restriction
            return Unknown.new(:no_annotation, "block parameter #{name} has no type restriction")
          end

          return declared(Syntax::TypeReader.read(restriction), scope(context))
        end

        if (declaration = facts.declaration(name))
          return declared(Syntax::TypeReader.read(declaration.declared_type), scope(context))
        end

        key = variable_key(name, context)
        return Unknown.new(:cycle, name) if visiting.includes?(key)

        if (from_block = block_parameter(name, context, locals, visiting + [key]))
          return from_block
        end

        return rescued_type(rescued, context) if rescued

        assignments = facts.assigned(name)
        if assignments.empty?
          return Unknown.new(
            :no_annotation, "#{name} is not a parameter and is never assigned here"
          )
        end
        if steps.any? { |step| assigning?(step) }
          return TypeRef.of(:nil)
        end

        assignments = same_block(assignments, facts.reassigned(name), context)
        assigned = Array(Resolution).new(assignments.size)
        deferred = Array(Crystal::ASTNode).new
        key = variable_key(name, context)
        assignments.each do |value|
          typed = value_type(value, locals) ||
                  remember_value(value, type_of(value, context, visiting + [key], locals), locals)
          if typed.is_a?(Unknown) && typed.reason.cycle?
            deferred << value
          else
            assigned << typed
          end
        end
        return union(assigned) if deferred.empty?

        seed = union(assigned)
        return Unknown.new(:cycle, name) if seed.is_a?(Unknown)

        seeded_locals = seeded(locals, name, seed)
        deferred.each do |value|
          typed = type_of(value, context, visiting + [key], seeded_locals)
          assigned << settled(name, seed, value, typed)
        end
        union(assigned)
      end

      private def branched(
        current : Resolution,
        step : Flow::Branched,
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        return current if !step.assigns && (current.is_a?(TypeVar) || current.is_a?(Unknown))

        exits = exits_for(context, visiting)
        results = Array(Resolution).new(step.branches.size)
        step.branches.each do |branch|
          body = branch.body
          entry = Flow.new(name, exits, facts_for(context))
          next if body && entry.exits?(body, step.within)

          entry.collect(step.cond, branch.positive, step.within)
          start = narrow(current, name, entry.steps, context, visiting, locals)
          if body && !body.is_a?(Crystal::Nop)
            inner = Flow.new(name, exits, facts_for(context))
            inner.walk(body, step.within + [body])
            start = narrow(start, name, inner.steps, context, visiting, locals)
          end
          results << start
        end
        return TypeRef.of(:no_return) if results.empty?

        union(results)
      end

      private def value_type(value : Crystal::ASTNode, locals : Array(Binding)) : Resolution?
        return unless locals.empty?

        @typed_values[value.object_id]?
      end

      private def remember_value(
        value : Crystal::ASTNode,
        typed : Resolution,
        locals : Array(Binding),
      ) : Resolution
        @typed_values[value.object_id] = typed if locals.empty? && !unsettled?(typed)
        typed
      end

      private def unsettled?(typed : Resolution) : Bool
        typed.is_a?(Unknown) && (typed.reason.cycle? || typed.reason.too_deep?)
      end

      private def settled(
        name : String,
        seed : Resolution,
        value : Crystal::ASTNode,
        typed : Resolution,
      ) : Resolution
        return typed if typed.is_a?(Unknown) || seed.is_a?(Unknown)
        return typed unless VariableReferences.include?(value, name)

        grown = members_of(typed).reject { |member| members_of(seed).includes?(member) }
        return typed if grown.empty?

        Unknown.new(
          :cycle,
          "#{name} widens on every pass (#{seed} then #{typed}); declare its type",
        )
      end

      private def members_of(resolution : Resolved) : Array(Resolution)
        resolution.is_a?(UnionRef) ? resolution.members : [resolution] of Resolution
      end

      private def seeded(locals : Array(Binding), name : String, seed : Resolution) : Array(Binding)
        return locals if seed.is_a?(Unknown)

        locals.reject(&.name.==(name)) << Binding.new(name, seed)
      end

      private def elements(
        nodes : Array(Crystal::ASTNode),
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
        & : Resolution -> Resolution
      ) : Resolution
        if nodes.empty?
          return Unknown.new(:no_annotation, "an empty literal needs `of T` to state its type")
        end

        typed = Array(Resolution).new(nodes.size)
        nodes.each { |element| typed << type_of(element, context, visiting, locals) }
        inner = union(typed)
        return inner if inner.is_a?(Unknown)

        yield inner
      end

      private def same_block(
        assignments : Array(Crystal::ASTNode),
        placed : Array(Reassignment),
        context : Syntax::Context,
      ) : Array(Crystal::ASTNode)
        block_call = context.blocks.last?
        return assignments unless block_call

        kept = assignments.select do |value|
          item = placed.find(&.value.same?(value))
          item.nil? || item.path.none?(Crystal::Block) || item.path.any?(&.same?(block_call))
        end
        kept.empty? ? assignments : kept
      end

      private def enclosing_rescue(name : String, context : Syntax::Context) : Int32?
        context.ancestors.rindex { |node| node.is_a?(Crystal::Rescue) && node.name == name }
      end

      private def rescued_type(rescued : Crystal::Rescue, context : Syntax::Context) : Resolution
        types = rescued.types
        return TypeRef.of(:exception) unless types

        union(types.map { |type| declared(Syntax::TypeReader.read(type), scope(context)) })
      end

      private def union(resolutions : Array(Resolution)) : Resolution
        members = Array(Resolution).new
        resolutions.each do |resolution|
          return resolution if resolution.is_a?(Unknown)
          next if resolution.is_a?(TypeRef) && resolution.is?(:no_return)
          if resolution.is_a?(UnionRef)
            resolution.members.each { |inner| members << inner unless members.includes?(inner) }
          else
            members << resolution unless members.includes?(resolution)
          end
        end
        return TypeRef.of(:no_return) if members.empty?

        members = absorb(members)
        members.size == 1 ? members[0] : UnionRef.new(members)
      end

      private def absorb(members : Array(Resolution)) : Array(Resolution)
        return members if members.size < 2

        members.reject do |member|
          next false unless member.is_a?(TypeRef)

          members.any? do |other|
            other.is_a?(TypeRef) && other.name != member.name &&
              other.arguments.empty? && covers?(other, member)
          end
        end
      end

      private def outside(call : Crystal::Call, context : Syntax::Context) : Syntax::Context
        enclosing_blocks = context.blocks[0...context.blocks.index!(call)]
        upto = context.ancestors.index(&.same?(call))
        outer_ancestors = upto ? context.ancestors[0..upto] : context.ancestors
        Syntax::Context.new(
          context.enclosing,
          context.type_vars,
          context.def_node,
          enclosing_blocks,
          outer_ancestors,
          context.path,
          context.instance,
        )
      end

      private def implicit_receiver(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(String),
      ) : Resolution
        scope = yield_scope(context)
        return implicit_target(call, context) if scope.is_a?(Unscoped) || scope.is_a?(Unknown)

        defs = @methods.named_on(scope, call.name, context.path)
        defs.empty? ? implicit_target(call, context) : scope
      end

      private def implicit_target(call : Crystal::Call, context : Syntax::Context) : Resolution
        this = implicit_self(context)
        return this unless this.is_a?(TypeRef) && @methods.extends_itself?(this.name)
        return this unless @methods.named_on(this, call.name, context.path).empty?

        metaclass = MetaRef.new(this)
        @methods.named_on(metaclass, call.name, context.path).empty? ? this : metaclass
      end

      private def opaque_block?(block_call : Crystal::Call) : Bool
        Index::MacroCall.like?(block_call, @workspace)
      end

      private def block_scope(
        block_call : Crystal::Call,
        context : Syntax::Context,
      ) : Resolution | Unscoped
        outer = outside(block_call, context)
        target = of_call(block_call, outer)
        return target if target.is_a?(Unknown)

        shape = shape_of(block_call, outer)
        defs = @methods.lookup(target, shape)
        if defs.empty?
          return Unknown.new(:unresolved_name, "no `#{block_call.name}` on #{target}")
        end

        scoped = defs.select(&.with_yield)
        return Unscoped.new if scoped.empty?

        union(scoped.map { |entry| with_scope(entry, target, shape.arguments) })
      end

      private def with_scope(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
      ) : Resolution
        definition = entry.node
        unless definition
          return Unknown.new(:no_annotation, "#{entry.qualified} yields with an unknown scope")
        end

        owner = entry.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        sites = Syntax::YieldSites.in(definition, enclosing, entry.free_vars, entry.path)
        scopes = Array(Resolution).new
        sites.each do |site|
          expression = site.node.scope
          next unless expression

          if expression.is_a?(Crystal::Var) && Syntax::WellKnown::SelfName.named?(expression.name)
            scopes << owning(entry, receiver)
          else
            scopes << type_of(expression, site.context, [entry.qualified], Array(Binding).new)
          end
        end
        if scopes.empty?
          return Unknown.new(:no_annotation, "#{entry.qualified} yields without a scope")
        end

        scope = return_scope(entry, receiver, arguments, Site::NONE)
        scope.is_a?(Unknown) ? union(scopes) : rebind(union(scopes), scope)
      end

      private def loop_result(block : Crystal::Block, site : Site) : Resolution
        values = break_values(block, site)
        values.empty? ? TypeRef.of(:no_return) : union(values)
      end

      private def break_values(block : Crystal::Block, site : Site) : Array(Resolution)
        Breaks.in(block).map do |found|
          exp = found.node.exp
          next TypeRef.of(:nil).as(Resolution) unless exp

          context = site.context.inside(block)
          found.ancestors.each { |ancestor| context = context.inside(ancestor) }
          type_of(exp, context.inside(found.node, exp), site.visiting, site.locals)
        end
      end

      private def implicit_self(context : Syntax::Context) : Resolution
        owner = context.owner
        return TypeRef.program if owner.is_a?(Index::TopLevel)

        this = TypeRef.new(owner, Array(Resolution).new)
        index = context.proc_index
        return implicit_self(context.outside_proc(index)) if index

        definition = context.def_node
        return (context.instance_code? ? this : MetaRef.new(this)) unless definition

        definition.receiver ? MetaRef.new(this) : this
      end

      private def enum_base(receiver : TypeRef) : Resolution
        namespace = @workspace.namespaces(receiver.name).find(&.is_a?(Index::EnumNamespace))
        base = namespace.is_a?(Index::EnumNamespace) ? namespace.base_type : nil
        return TypeRef.of(:int32) unless base.is_a?(Syntax::Type)

        @types.resolve_lexically(base, Scope.of(receiver.name.rpartition("::")[0]))
      end

      private def compacted(receiver : TypeRef) : Resolution
        element = receiver.arguments[0]?
        return receiver unless element.is_a?(UnionRef)

        kept = element.members.reject { |member| member.is_a?(TypeRef) && member.is?(:nil) }
        TypeRef.of(:array, [union(kept)] of Resolution)
      end

      private def forwarded(
        entry : Index::Def,
        target : Crystal::ASTNode,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        owner = entry.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        context = Syntax::Context.new(enclosing, Array(String).new, nil, entry.path, true)
        return Unknown.new(:cycle, entry.qualified) if site.visiting.includes?(entry.qualified)

        visiting = site.visiting + [entry.qualified]
        delegate = type_of(target, context, visiting, Array(Binding).new)
        return delegate if delegate.is_a?(Unknown)

        shape = Methods::Call.new(entry.name, arguments.size, !site.block.nil?, arguments)
        result_of(delegate, shape, Site.new(site.block, site.context, site.locals, visiting))
      end

      private def read_instance_var(
        entry : Index::Def,
        name : String,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        owner = entry.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end
        return Unknown.new(:cycle, entry.qualified) if site.visiting.includes?(entry.qualified)

        visiting = site.visiting + [entry.qualified]
        entries = @workspace.instance_vars_of(owner).select(&.name.==(name))
        if entries.empty?
          context = Syntax::Context.new([owner], @types.type_vars_of(owner), nil, entry.path)
          return instance_var(name, context, visiting)
        end

        scope = return_scope(entry, receiver, arguments, site)
        return scope if scope.is_a?(Unknown)

        instance_var_from(entries, owner, scope, visiting)
      end

      private def return_scope(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Scope | Unknown
        owner = entry.owner
        bindings = Array(Binding).new
        type_vars = entry.free_vars.dup
        free_vars = entry.free_vars.dup
        unless owner.is_a?(Index::TopLevel)
          instance = receiver.is_a?(MetaRef) ? receiver.of : receiver
          inherited = instance.is_a?(TypeRef) ? @types.bindings(instance, owner) : bindings
          if inherited.is_a?(Unknown)
            return inherited unless receiver.is_a?(MetaRef) && @types.type_vars_of(owner).empty?

            inherited = Array(Binding).new
          end
          bindings = inherited.dup
          bindings << Binding.new("self", instance)
          owner_vars = @types.type_vars_of(owner)
          type_vars = owner_vars + type_vars
          if receiver.is_a?(MetaRef)
            free_vars.concat(owner_vars.reject { |name| bindings.any?(&.name.==(name)) })
          end
        end

        scope = Scope.new(owner, type_vars, bindings, entry.path)
        bind_arguments(entry, arguments, free_vars, bindings, scope)
        bind_named(entry, site.named, free_vars, bindings, scope)
        bind_block(entry, site, free_vars, bindings, scope)
        entry.free_vars.each do |free_var|
          next if bindings.any?(&.name.==(free_var))

          bindings << Binding.new(
            free_var,
            Unknown.new(
              :free_variable,
              "#{free_var} is not fixed by the arguments or block of #{entry.qualified}",
            ),
          )
        end
        scope
      end

      private def constant(
        path : Crystal::Path,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        scope = scope(context)
        if path.names.size == 1 && !path.global? && scope.type_vars.includes?(path.names[0])
          return MetaRef.new(TypeVar.new(path.names[0]))
        end
        located = @types.locate_any(Syntax::Named.new(path.names, path.global?), scope)
        return located if located.is_a?(Unknown)

        constants = @workspace.constants(located)
        if constants.empty?
          resolved = @types.resolve(Syntax::Named.new(path.names, path.global?), scope)
          return metaclass_of(resolved)
        end
        return Unknown.new(:cycle, located) if visiting.includes?(located)

        union(constants.map { |entry| constant_type(entry, located, visiting + [located]) })
      end

      private def metaclass_of(resolved : Resolution) : Resolution
        case resolved
        in TypeRef, TypeVar then MetaRef.new(resolved)
        in UnionRef
          members = Array(Resolution).new(resolved.members.size)
          resolved.members.each { |member| members << metaclass_of(member) }
          UnionRef.new(members)
        in MetaRef, Unknown then resolved
        end
      end

      private def constant_type(
        entry : Index::Constant,
        name : String,
        visiting : Array(String),
      ) : Resolution
        owner = name.rpartition("::")[0]
        if @workspace.namespaces(owner).any?(Index::EnumNamespace)
          return TypeRef.new(owner, Array(Resolution).new)
        end
        owner_scope = owner.empty? ? Scope::TOP : Scope.of(owner)
        expression = entry.expression
        enclosing = owner.empty? ? Array(String).new : [owner]
        context = Syntax::Context.new(enclosing, Array(String).new, nil, entry.path)
        if expression.is_a?(Crystal::Path)
          return type_of(expression, context, visiting, Array(Binding).new)
        end

        type = entry.type
        return @types.resolve(type, owner_scope) if type.is_a?(Syntax::Type)
        unless expression
          return Unknown.new(:no_annotation, "#{name} has no value to type")
        end

        type_of(expression, context, visiting, Array(Binding).new)
      end

      private def block_parameter(
        name : String,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(String),
      ) : Resolution?
        context.blocks.reverse_each do |call|
          block = call.block
          next unless block
          index = block.args.index(&.name.==(name))
          unpacked = index ? nil : unpacked_position(block, name)
          index ||= unpacked.try(&.[0])
          next unless index

          outer = outside(call, context)
          receiver = of_call(call, outer, locals, visiting)
          return receiver if receiver.is_a?(Unknown)

          input = @block_inputs[{call.object_id, index}]? || begin
            shape = shape_of(call, outer, locals, visiting)
            computed = block_inputs(receiver, shape, index, block.args.size)
            if locals.empty? && !unsettled?(computed)
              @block_inputs[{call.object_id, index}] = computed
            end
            computed
          end
          return input unless unpacked

          return tuple_element(input, unpacked[1], name)
        end
        nil
      end

      private def unpacked_position(block : Crystal::Block, name : String) : Tuple(Int32, Int32)?
        block.unpacks.try &.each do |index, expressions|
          position = expressions.expressions.index do |var|
            var.is_a?(Crystal::Var) && var.name == name
          end
          return {index, position} if position
        end
        nil
      end

      private def tuple_element(input : Resolution, position : Int32, name : String) : Resolution
        return input if input.is_a?(Unknown)
        unless input.is_a?(TypeRef)
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end
        if input.is?(:tuple)
          element = input.arguments[position]?
          return element || Unknown.new(:unsupported, "#{name} unpacks past the tuple's size")
        end

        chain = @types.ancestors(input.name)
        inherits = !chain.is_a?(Unknown) && chain.includes?(CoreType::Indexable.type_name)
        indexable = input.is?(:indexable) || inherits
        unless indexable
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end

        element = input.arguments[0]?
        element || Unknown.new(:unsupported, "#{name} unpacks #{input} with no element type")
      end

      private def block_inputs(
        receiver : Resolved,
        shape : Methods::Call,
        index : Int32,
        parameters : Int32,
      ) : Resolution
        if receiver.is_a?(UnionRef)
          per_member = Array(Resolution).new(receiver.members.size)
          receiver.members.each do |member|
            per_member << if member.is_a?(Unknown)
              member
            else
              block_inputs(member, shape, index, parameters)
            end
          end
          return union(per_member)
        end

        defs = @methods.lookup(receiver, shape)
        return Unknown.new(:unresolved_name, "no `#{shape.name}` on #{receiver}") if defs.empty?

        inputs = Array(Resolution).new(defs.size)
        defs.each do |entry|
          inputs << block_input(entry, receiver, shape.arguments, index, parameters)
        end
        union(inputs)
      end

      private def block_input(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        index : Int32,
        parameters : Int32,
      ) : Resolution
        proc_input = proc_block_input(entry, receiver, index)
        return proc_input if proc_input

        restriction = block_restriction(entry)
        if restriction.nil? || restriction.inputs.empty?
          return yielded(entry, index, receiver, arguments, parameters)
        end

        scope = return_scope(entry, receiver, arguments, Site::NONE)
        return scope if scope.is_a?(Unknown)

        if restriction.inputs.size == 1 && parameters > 1
          yielded = @types.resolve(restriction.inputs[0], scope)
          element = tuple_element(yielded, index)
          return element if element
        end
        input = restriction.inputs[index]?
        return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values") unless input

        @types.resolve(input, scope)
      end

      private def tuple_element(yielded : Resolution, index : Int32) : Resolution?
        if yielded.is_a?(TypeRef) && yielded.is?(:tuple)
          return yielded.arguments[index]?
        end
        return unless yielded.is_a?(UnionRef)

        elements = yielded.members.map do |member|
          return unless member.is_a?(TypeRef) && member.is?(:tuple)

          member.arguments[index]? || return
        end
        union(elements)
      end

      private def yielded(
        entry : Index::Def,
        index : Int32,
        receiver : Resolved,
        arguments : Array(Resolution),
        parameters : Int32,
      ) : Resolution
        definition = entry.node
        unless definition
          return Unknown.new(:no_annotation, "#{entry.qualified} does not state what it yields")
        end

        owner = entry.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        owner_vars = owner.is_a?(String) ? @types.type_vars_of(owner) : Array(String).new
        type_vars = entry.free_vars + owner_vars
        sites = Syntax::YieldSites.in(definition, enclosing, type_vars, entry.path)
        if sites.empty?
          return Unknown.new(:no_annotation, "#{entry.qualified} never yields")
        end

        values = Array(Resolution).new(sites.size)
        sites.each do |site|
          exps = site.node.exps
          if exps.size == 1 && parameters > 1
            packed = type_of(exps[0], site.context, [entry.qualified], Array(Binding).new)
            if packed.is_a?(TypeRef) && packed.is?(:tuple) && (element = packed.arguments[index]?)
              values << element
              next
            end
          end
          expression = exps[index]?
          unless expression
            return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values")
          end
          values << type_of(expression, site.context, [entry.qualified], Array(Binding).new)
        end
        scope = return_scope(entry, receiver, arguments, Site::NONE)
        scope.is_a?(Unknown) ? union(values) : rebind(union(values), scope)
      end

      private def literal_collection(
        node : Crystal::ArrayLiteral,
        context : Syntax::Context,
      ) : String
        name = node.name
        return CoreType::Array.type_name unless name

        resolved = declared(Syntax::TypeReader.read(name), scope(context))
        resolved.is_a?(TypeRef) ? resolved.name : CoreType::Array.type_name
      end

      private def rebind(resolution : Resolution, scope : Scope) : Resolution
        case resolution
        in TypeVar then scope.bound(resolution.name) || resolution
        in TypeRef
          TypeRef.new(resolution.name, resolution.arguments.map { |arg| rebind(arg, scope) })
        in UnionRef then union(resolution.members.map { |member| rebind(member, scope) })
        in MetaRef
          inner = rebind(resolution.of, scope)
          inner.is_a?(TypeRef) || inner.is_a?(TypeVar) ? MetaRef.new(inner) : resolution
        in Unknown then resolution
        end
      end

      private def proc_block_input(
        entry : Index::Def,
        receiver : Resolved,
        index : Int32,
      ) : Resolution?
        return unless receiver.is_a?(MetaRef)

        proc = receiver.of
        return unless proc.is_a?(TypeRef) && proc.is?(:proc) && proc.arguments.size > index + 1

        restriction = entry.parameters.find(&.kind.block?).try(&.restriction)
        return unless restriction.is_a?(Syntax::SelfType)

        proc.arguments[index]
      end

      private def block_restriction(entry : Index::Def) : Syntax::Proc?
        restriction = entry.parameters.find(&.kind.block?).try(&.restriction)
        return restriction if restriction.is_a?(Syntax::Proc)

        shim = @shims.find(entry)
        return unless shim

        shimmed = shim.entry.parameters.find(&.kind.block?).try(&.restriction)
        shimmed.is_a?(Syntax::Proc) ? shimmed : nil
      end

      private def bind_block(
        entry : Index::Def,
        site : Site,
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        restriction = block_restriction(entry)
        return unless restriction
        output = restriction.output
        return unless output

        block = site.block
        unless block
          passed = site.block_arg
          return unless passed

          result = passed_block_result(passed, site, scope, restriction)
          Unify.bind(output, result, free_vars, bindings, @types, scope)
          return
        end

        inputs = restriction.inputs.map { |input| @types.resolve(input, scope) }
        locals = site.locals.dup
        block.args.each_with_index do |argument, index|
          input = inputs[index]?
          locals << Binding.new(argument.name, input) if input
        end
        body = block.body
        result = type_of(body, site.context.inside(block, body), site.visiting, locals)
        Unify.bind(output, result, free_vars, bindings, @types, scope)
      end

      private def passed_block_result(
        passed : Crystal::ASTNode,
        site : Site,
        scope : Scope,
        restriction : Syntax::Proc,
      ) : Resolution
        if passed.is_a?(Crystal::ProcPointer)
          return proc_pointer_result(passed, site, scope, restriction)
        end

        proc = type_of(passed, site.context, site.visiting, site.locals)
        return proc if proc.is_a?(Unknown)
        if proc.is_a?(TypeRef) && proc.is?(:proc) && (output = proc.arguments.last?)
          return output
        end

        Unknown.new(:no_annotation, "the passed block is a #{proc}, not a Proc with a signature")
      end

      private def proc_pointer_result(
        pointer : Crystal::ProcPointer,
        site : Site,
        scope : Scope,
        restriction : Syntax::Proc,
      ) : Resolution
        inputs = restriction.inputs.map { |input| @types.resolve(input, scope) }
        arguments = Array(Resolution).new(pointer.args.size)
        pointer.args.each_with_index do |argument, index|
          typed = Syntax::TypeReader.read(argument)
          arguments << if typed.is_a?(Syntax::Type)
            @types.resolve(typed, scope(site.context))
          else
            inputs[index]? || Unknown.new(:unsupported, "proc pointer argument #{argument}")
          end
        end
        obj = pointer.obj
        receiver = if obj
                     type_of(obj, site.context, site.visiting, site.locals)
                   else
                     implicit_self(site.context)
                   end
        return receiver if receiver.is_a?(Unknown)

        shape = Methods::Call.new(pointer.name, arguments.size, false, arguments)
        result_of(receiver, shape, Site::NONE)
      end

      private def bind_arguments(
        entry : Index::Def,
        arguments : Array(Resolution),
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        positional = entry.parameters.select(&.kind.positional?)
        positional.each_with_index do |parameter, index|
          restriction = parameter.restriction
          next unless restriction.is_a?(Syntax::Type)

          argument = arguments[index]? || defaulted(parameter, scope)
          next unless argument

          Unify.bind(restriction, argument, free_vars, bindings, @types, scope)
        end
      end

      private def defaulted(parameter : Index::Parameter, scope : Scope) : Resolution?
        default_type = parameter.default_type
        default_type ? @types.resolve(default_type, scope) : nil
      end

      private def bind_named(
        entry : Index::Def,
        named : Array(Binding),
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        named.each do |argument|
          parameter = entry.parameters.find(&.external_name.==(argument.name))
          restriction = parameter.try(&.restriction)
          next unless restriction.is_a?(Syntax::Type)

          Unify.bind(restriction, argument.value, free_vars, bindings, @types, scope)
        end
      end

      private def scope(context : Syntax::Context) : Scope
        Scope.new(context.owner, context.type_vars, Array(Binding).new, context.path)
      end

      private def declared(type : Syntax::TypeReader::Outcome, scope : Scope) : Resolution
        return Unknown.new(:unsupported, type.source) if type.is_a?(Syntax::TypeReader::Unsupported)

        @types.resolve(type, scope)
      end
    end
  end
end
