require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/shims"
require "../index/evident"
require "../index/macro_call"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./methods"
require "./macro_precedence"
require "./precision"
require "./unify"
require "./render"
require "./local_declarations"
require "./body_facts"
require "./memos"
require "./visit"
require "./frame"
require "./unions"
require "./narrowing"
require "./block_inputs"
require "./macro_expansions"
require "./dispatch"
require "./instance_var_types"
require "./special"
require "./local_assignments"
require "./variable_references"
require "./flow"
require "./call_exits"
require "./escapes"
require "../syntax/yield_sites"
require "../syntax"
require "../syntax/defined_variables"
require "../syntax/expansion_locals"

require "../syntax/well_known"

module Heucristic
  module Resolve
    class Receiver
      include BlockInputs::Typer
      include Dispatch::Typer

      DEPTH_LIMIT = 48

      BE_NIL_EXPECTATION = Index::Public.new("Spec::BeNilExpectation")

      alias Verdict = MacroPrecedence::Verdict

      record Unscoped

      record CallKey,
        call : UInt64,
        ancestors : Int32,
        first_ancestor : UInt64,
        last_ancestor : UInt64,
        blocks : Int32,
        last_block : UInt64 do
        def self.of(call : Crystal::Call, context : Syntax::Context) : CallKey
          new(
            call.object_id,
            context.ancestors.size,
            context.ancestors.first?.try(&.object_id) || 0_u64,
            context.ancestors.last?.try(&.object_id) || 0_u64,
            context.blocks.size,
            context.blocks.last?.try(&.object_id) || 0_u64,
          )
        end
      end

      record ConstructionKey, call : CallKey, visiting : Array(Visit)

      record CachedCall, node : Crystal::Call, context : Syntax::Context, result : Resolution

      record Site,
        block : Crystal::Block?,
        frame : Frame,
        named : Array(Binding) = Array(Binding).new,
        block_arg : Crystal::ASTNode? = nil do
        NONE = new(
          nil,
          Frame.of(Syntax::Context.new(Array(Index::Identity).new, Array(String).new, nil)),
        )

        def context : Syntax::Context
          frame.context
        end

        def locals : Array(Binding)
          frame.locals
        end

        def visiting : Array(Visit)
          frame.visiting
        end
      end

      COMPARISONS = {"<", "<=", ">", ">="}

      def self.chained_comparison?(call : Crystal::Call) : Bool
        return false unless COMPARISONS.includes?(call.name)

        inner = call.obj
        inner.is_a?(Crystal::Call) && COMPARISONS.includes?(inner.name) && inner.args.size == 1
      end

      def initialize(
        @workspace : Index::Workspace,
        @shims : Index::Shims,
        @types : Types,
        @methods : Methods,
      ) : Nil
        @precedence = MacroPrecedence.new(@workspace, @methods)
        @depth = 0
        @memos = Memos.new
        @unions = Unions.new(@types)
        @narrowing = Narrowing.new(@types, @methods, @unions)
        @depth_exhausted = 0
      end

      def result_of(call : Crystal::Call, frame : Frame) : Resolution
        if frame.locals.empty? && !frame.visiting.empty? &&
           Syntax::WellKnown::New.named?(call.name)
          return constructed_result(call, frame.context, frame.visiting)
        end

        return computed_result(call, frame) unless frame.untracked?

        key = CallKey.of(call, frame.context)
        cached = @memos.call_results[key]?
        return cached.result if cached && cached.context.same_as?(frame.context)

        exhausted = @depth_exhausted
        result = computed_result(call, frame)
        if exhausted == @depth_exhausted && !unsettled?(result)
          @memos.call_results[key] = CachedCall.new(call, frame.context.copy, result)
        end
        result
      end

      def macro_precedence(
        call : Crystal::Call,
        context : Syntax::Context,
      ) : MacroPrecedence::Verdict
        return Verdict::Def if !call.obj.nil? || @workspace.macros(call.name).empty?
        return Verdict::Undecided unless yield_scope(context).is_a?(Unscoped)

        @precedence.verdict(call, implicit_self(context), context.path)
      end

      def forwarded_receiver(receiver : Resolved) : Resolution?
        dispatch.forwarded_receiver(receiver)
      end

      def select_action(call : Crystal::Call, context : Syntax::Context) : Crystal::Call?
        return unless context.select_condition?(call)

        Crystal::Call.new(call.obj, select_action_name(call.name), call.args)
      end

      def shape_of(call : Crystal::Call, context : Syntax::Context) : Methods::CallShape
        shape_of(call, Frame.of(context))
      end

      def shape_of(call : Crystal::Call, frame : Frame) : Methods::CallShape
        arguments = Array(Methods::CallShape::Argument).new(call.args.size)
        call.args.each do |argument|
          type = type_of(argument, frame)
          arguments << Methods::CallShape::Argument.new(type, Precision.of(argument))
        end
        named = Array(Binding).new
        call.named_args.try &.each do |argument|
          value = type_of(argument.value, frame)
          named << Binding.new(argument.name, value)
        end
        Methods::CallShape.new(
          call.name,
          call.args.size,
          blocky?(call),
          arguments,
          named,
          call.obj.nil?,
          frame.context.path,
        )
      end

      def of_call(call : Crystal::Call, context : Syntax::Context) : Resolution
        of_call(call, Frame.of(context))
      end

      def of_call(call : Crystal::Call, frame : Frame) : Resolution
        receiver = call.obj
        return implicit_receiver(call, frame.context) unless receiver

        type_of(receiver, frame)
      end

      def yield_scope(context : Syntax::Context) : Resolution | Unscoped
        context.blocks.reverse_each do |block_call|
          next if opaque_block?(block_call)

          scope = @memos.yield_scopes[block_call.object_id]? || begin
            computed = block_scope(block_call, context)
            if computed.is_a?(Unscoped) || !unsettled?(computed)
              @memos.yield_scopes[block_call.object_id] = computed
            end
            computed
          end
          return scope unless scope.is_a?(Unscoped)
        end
        Unscoped.new
      end

      def variable(name : String, context : Syntax::Context) : Resolution
        variable(name, Frame.of(context))
      end

      def instance_var(name : String, context : Syntax::Context) : Resolution
        instance_var_types.of(name, context, Array(Visit).new)
      end

      def return_type(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution) = Array(Resolution).new,
        site : Site = Site::NONE,
      ) : Resolution
        receiver = owning(entry, receiver)
        constructed = constructed_type(entry, receiver)
        return constructed if constructed

        special = Special.for(entry)
        if special
          answer = special_type(special, entry, receiver, arguments, site)
          return answer if answer
        end

        case (restriction = entry.return_type)
        in Index::Unrestricted
          unrestricted_type(entry, special, receiver, arguments, site)
        in Syntax::TypeReader::Unsupported
          Unknown.new(:unsupported, restriction.source)
        in Syntax::Type
          restricted_type(restriction, entry, special, receiver, arguments, site)
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

      def implementations(receiver : Resolved, shape : Methods::CallShape) : Array(Index::Def)
        found = @methods.dispatch(receiver, shape).dup
        return found if found.empty? || !receiver.is_a?(TypeRef)

        @methods.concrete_subclasses(receiver, shape.caller_path).each do |below|
          next unless dispatch.overridden?(below, receiver, shape)

          found.concat(@methods.lookup(below, shape))
        end
        found.uniq!
      end

      def super_targets(call : Crystal::Call, context : Syntax::Context) : Array(Index::Def)
        receiver = of_call(call, context)
        definition = context.def_node
        owner = context.owner
        unless receiver.is_a?(Resolved) && definition && owner.is_a?(Index::Identity)
          return Array(Index::Def).new
        end

        shape = shape_of(call, context)
        @methods.lookup_super(receiver, owner, parent_call(call, shape, definition))
      end

      def dispatch : Dispatch
        @dispatch ||= Dispatch.new(@workspace, @methods, @shims, @unions, self)
      end

      def invalidate : Nil
        @memos.clear
      end

      def forget(path : String) : Nil
        @memos.forget(path)
      end

      def remembered_exit(
        call : Crystal::Call,
        context : Syntax::Context,
        visiting : Array(Visit),
        & : Resolution -> Bool
      ) : Bool
        answers = exit_answers(call)
        cached = answers.try(&.[call.object_id]?)
        return cached unless cached.nil?

        receiver = of_call(call, Frame.new(context, Array(Binding).new, visiting))
        answer = yield receiver
        answers[call.object_id] = answer if answers && !unsettled?(receiver)
        answer
      end

      def no_return?(entry : Index::Def) : Bool
        no_return?(entry, Array(Visit).new)
      end

      def narrowing_steps(name : String, context : Syntax::Context) : Array(Flow::Step)
        exits = exits_for(context, Array(Visit).new)
        Flow.steps(name, context.ancestors, exits, facts_for(context))
      end

      def typed(node : Crystal::ASTNode, context : Syntax::Context) : Resolution
        type_of(node, Frame.of(context))
      end

      def type_of(entry : Index::Constant) : Resolution
        constant_type(entry, Array(Visit).new)
      end

      def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(Visit),
        locals : Array(Binding),
      ) : Resolution
        type_of(node, Frame.new(context, locals, visiting))
      end

      def type_of(node : Crystal::ASTNode, frame : Frame) : Resolution
        if @depth >= DEPTH_LIMIT
          @depth_exhausted += 1
          return Unknown.new(:too_deep, "typing `#{node}` needs more than #{DEPTH_LIMIT} steps")
        end

        @depth += 1
        begin
          typed(node, frame)
        ensure
          @depth -= 1
        end
      end

      def scope_of(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
      ) : Scope | Unknown
        return_scope(entry, receiver, arguments, Site::NONE)
      end

      def call_on(receiver : Resolved, shape : Methods::CallShape) : Resolution
        dispatch.result(receiver, shape)
      end

      private def no_return?(entry : Index::Def, visiting : Array(Visit)) : Bool
        restriction = entry.return_type
        if restriction.is_a?(Index::Unrestricted)
          shim = @shims.find(entry)
          restriction = shim.return_type if shim
        end
        if restriction.is_a?(Syntax::Named) && restriction.names == [CoreType::NoReturn.type_name]
          return true
        end

        tail = entry.exit_call
        return false unless tail
        return true if KnownExits.new.terminates?(Crystal::Call.new(nil, tail))
        return false if visiting.includes?(DefVisit.of(entry))

        owner = entry.owner
        return false unless owner.is_a?(Index::Identity)

        callees = @methods.named_on(TypeRef.new(owner, Array(Resolution).new), tail)
        deeper = visiting + [DefVisit.of(entry)]
        !callees.empty? && callees.all? { |callee| no_return?(callee, deeper) }
      end

      private def case_subject(
        frame : Frame,
      ) : Resolution
        enclosing = frame.context.ancestors.reverse_each.find { |node| node.is_a?(Crystal::Case) }
        subject = enclosing.is_a?(Crystal::Case) ? enclosing.cond : nil
        unless subject
          return Unknown.new(:unsupported, "an implicit object outside a case")
        end
        if subject.is_a?(Crystal::Expressions) && subject.expressions.size == 1
          subject = subject.expressions[0]
        end

        type_of(subject, frame)
      end

      private def super_result(
        call : Crystal::Call,
        receiver : Resolved,
        shape : Methods::CallShape,
        site : Site,
      ) : Resolution
        definition = site.context.def_node
        owner = site.context.owner
        unless definition && owner.is_a?(Index::Identity)
          return Unknown.new(:no_annotation, "super outside a method")
        end

        return TypeRef.of(:nil) if Syntax::WellKnown::Initialize.named?(definition.name)

        defs = @methods.lookup_super(receiver, owner, parent_call(call, shape, definition))
        if defs.empty?
          return Unknown.new(:unresolved_name, "no `#{definition.name}` above #{owner}")
        end

        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << return_type(entry, receiver, shape.types, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1

        Unknown.new(:ambiguous, "#{defs.size} overloads of `super` do not agree on a type")
      end

      private def select_action_name(name : String) : String
        if name.ends_with?('!')
          "#{name[0...-1]}_select_action!"
        elsif name.ends_with?('?')
          "#{name[0...-1]}_select_action?"
        else
          "#{name}_select_action"
        end
      end

      private def blocky?(call : Crystal::Call) : Bool
        !call.block.nil? || !call.block_arg.nil?
      end

      private def case_value(
        node : Crystal::Case,
        frame : Frame,
      ) : Resolution
        branches = Array(Resolution).new(node.whens.size + 1)
        node.whens.each do |branch|
          inner = frame.context.inside(node, branch).inside(branch.body)
          branches << type_of(branch.body, frame.within(inner))
        end
        otherwise = node.else
        if otherwise
          branches << type_of(otherwise, frame.inside(node, otherwise))
        elsif !node.exhaustive?
          branches << TypeRef.of(:nil)
        end
        @unions.union(branches)
      end

      private def select_value(
        node : Crystal::Select,
        frame : Frame,
      ) : Resolution
        branches = Array(Resolution).new(node.whens.size + 1)
        node.whens.each do |branch|
          inner = frame.context.inside(node, branch).inside(branch.body)
          branches << type_of(branch.body, frame.within(inner))
        end
        if (otherwise = node.else)
          branches << type_of(otherwise, frame.inside(node, otherwise))
        end
        @unions.union(branches)
      end

      private def rescued_value(
        node : Crystal::ExceptionHandler,
        frame : Frame,
      ) : Resolution
        branches = Array(Resolution).new
        normal = node.else || node.body
        branches << type_of(normal, frame.inside(node, normal))
        node.rescues.try &.each do |handler|
          inner = frame.context.inside(node, handler).inside(handler.body)
          branches << type_of(handler.body, frame.within(inner))
        end
        @unions.union(branches)
      end

      private def op_assigned(
        node : Crystal::OpAssign,
        frame : Frame,
      ) : Resolution
        current = type_of(node.target, frame)
        value = type_of(node.value, frame)
        if node.op == "||"
          present = @narrowing.truthy(current)
          return value if present.is_a?(TypeRef) && present.is?(:nil)

          return @unions.union([present, value] of Resolution)
        end
        return @unions.union([@narrowing.falsey(current), value] of Resolution) if node.op == "&&"
        return current if current.is_a?(Unknown)

        dispatch.result(current, Methods::CallShape.of_types(node.op, [value] of Resolution, false))
      end

      private def hash_literal(
        node : Crystal::HashLiteral,
        frame : Frame,
      ) : Resolution
        if node.entries.empty?
          return Unknown.new(:no_annotation, "an empty hash literal needs `of K => V`")
        end

        keys = Array(Resolution).new(node.entries.size)
        values = Array(Resolution).new(node.entries.size)
        node.entries.each do |entry|
          keys << type_of(entry.key, frame)
          values << type_of(entry.value, frame)
        end
        key = @unions.union(keys)
        return key if key.is_a?(Unknown)
        value = @unions.union(values)
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

        @types.resolve(Syntax::TypeReader.read(output), Scope.of(context))
      end

      private def exits_for(context : Syntax::Context, visiting : Array(Visit)) : CallExits
        CallExits.new(@methods, implicit_self(context), self, context, visiting)
      end

      private def exit_answers(call : Crystal::Call) : Hash(UInt64, Bool)?
        filename = call.location.try(&.filename)
        return unless filename.is_a?(String)

        @memos.exit_answers(filename)
      end

      private def owning(entry : Index::Def, receiver : Resolved) : Resolved
        owner = entry.owner
        return receiver unless owner.is_a?(Index::Identity) && receiver.is_a?(TypeRef)
        return receiver if receiver.identity == owner || @workspace.module?(receiver.identity)

        chain = @types.ancestors(receiver.identity)
        return receiver if chain.is_a?(Array(Index::Identity)) && chain.includes?(owner)

        TypeRef.new(owner, Array(Resolution).new)
      end

      private def labelled_element_at(receiver : TypeRef, call : Crystal::Call) : Resolution?
        return unless call.name.in?("[]", "[]?") && call.args.size == 1

        key = call.args[0]
        return unless key.is_a?(Crystal::SymbolLiteral)

        index = receiver.labels.index(key.value)
        member = index ? receiver.arguments[index]? : nil
        return member || TypeRef.of(:nil) if call.name == "[]?"

        member || Unknown.new(:unresolved_name, "no key #{key.value.inspect} in #{receiver}")
      end

      private def tuple_element_at(receiver : TypeRef, call : Crystal::Call) : Resolution?
        return unless call.name.in?("[]", "[]?") && call.args.size == 1
        return if receiver.arguments.empty?

        literal = call.args[0]
        return unless literal.is_a?(Crystal::NumberLiteral)

        index = literal.value.to_i?
        return unless index

        member = receiver.arguments[index]?
        return member || TypeRef.of(:nil) if call.name == "[]?"

        member || Unknown.new(:unresolved_name, "#{receiver} has no element #{index}")
      end

      private def constructed_type(
        entry : Index::Def,
        receiver : Resolved,
      ) : Resolution?
        return unless receiver.is_a?(MetaRef)

        return receiver.of if Syntax::WellKnown::Initialize.named?(entry.name)

        instance = receiver.of
        proc_class = instance.is_a?(TypeRef) && instance.is?(:proc)
        return unless proc_class && Syntax::WellKnown::New.named?(entry.name)

        receiver.of if entry.return_type.is_a?(Index::Unrestricted)
      end

      private def special_type(
        special : Special,
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution?
        case special
        in .object_class?  then class_of(receiver)
        in .enum_value?    then enum_base(receiver) if receiver.is_a?(TypeRef)
        in .array_compact? then compacted(receiver) if receiver.is_a?(TypeRef)
        in .proc_call?
          if receiver.is_a?(TypeRef)
            receiver.arguments.last? || Unknown.new(:unsupported, "a proc without a signature")
          end
        in .tuple_first?           then tuple_members(receiver).try(&.first?)
        in .tuple_last?            then tuple_members(receiver).try(&.last?)
        in .tuple_first_or_nil?    then nilable_member(tuple_members(receiver).try(&.first?))
        in .tuple_last_or_nil?     then nilable_member(tuple_members(receiver).try(&.last?))
        in .tuple_map?             then tuple_mapped(entry, receiver, arguments, site)
        in .named_tuple_values?    then labelled_values(receiver)
        in .named_tuple_keys?      then labelled_keys(receiver)
        in .should_not?            then TypeRef.of(:no_return) if nil_asserted?(receiver, arguments)
        in .enumerable_zip?        then zipped(receiver, arguments, false) unless site.block
        in .enumerable_zip_or_nil? then zipped(receiver, arguments, true) unless site.block
        in .enumerable_to_h?
          pairs_to_hash(receiver) if receiver.is_a?(TypeRef) && !site.block
        in .enum_each?, .loop? then nil
        end
      end

      private def unrestricted_type(
        entry : Index::Def,
        special : Special?,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        shim = @shims.find(entry)
        return return_type(shim, receiver, arguments, site) if shim

        looped = site.block
        return loop_result(looped, site) if special.try(&.loop?) && looped

        if receiver.is_a?(TypeRef) && arguments.empty? && !site.block
          known = Syntax::WellKnown.from_name(entry.name)
          return receiver if known && known.copies?
        end
        if (target = entry.forwards_to)
          return forwarded(entry, target, arguments, site)
        end
        if (read = entry.reads)
          value = instance_var_types.read(entry, read.name, site.visiting) do
            return_scope(entry, receiver, arguments, site)
          end
          return read.asserted ? @narrowing.truthy(value) : value
        end

        Unknown.new(:no_annotation, "#{entry.qualified} has no return type restriction")
      end

      private def restricted_type(
        restriction : Syntax::Type,
        entry : Index::Def,
        special : Special?,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        scope = return_scope(entry, receiver, arguments, site)
        return scope if scope.is_a?(Unknown)

        if special.try(&.enum_each?) && (yielded = enum_each(receiver, scope))
          return yielded
        end

        @types.resolve(restriction, scope)
      end

      private def class_of(receiver : Resolved) : Resolution?
        case receiver
        in TypeRef                       then MetaRef.new(receiver)
        in MetaRef                       then receiver
        in UnionRef, TypeVar, ProgramRef then nil
        end
      end

      private def tuple_members(receiver : Resolved) : Array(Resolution)?
        receiver.arguments if receiver.is_a?(TypeRef) && receiver.is?(:tuple)
      end

      private def nilable_member(member : Resolution?) : Resolution?
        @unions.union([member, TypeRef.of(:nil)] of Resolution) if member
      end

      private def tuple_mapped(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution?
        members = tuple_members(receiver)
        return if members.nil? || members.empty?

        scope = return_scope(entry, receiver, arguments, site)
        return scope if scope.is_a?(Unknown)

        mapped = scope.bound("U")
        return unless mapped

        TypeRef.of(:tuple, Array(Resolution).new(members.size, mapped))
      end

      private def labelled_values(receiver : Resolved) : Resolution?
        TypeRef.of(:tuple, receiver.arguments) if receiver.is_a?(TypeRef) && receiver.labelled?
      end

      private def labelled_keys(receiver : Resolved) : Resolution?
        return unless receiver.is_a?(TypeRef) && receiver.labelled?

        symbols = Array(Resolution).new(receiver.arguments.size) { TypeRef.of(:symbol) }
        TypeRef.of(:tuple, symbols)
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
          members << (nilable ? @unions.union([other, nil_type] of Resolution) : other)
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
        bindings = @types.bindings(collection, CoreType::Enumerable.identity)
        return bindings if bindings.is_a?(Unknown)

        bindings.find(&.name.==("T")).try(&.value) ||
          Unknown.new(:no_annotation, "#{collection} does not state its element type")
      end

      private def scope_in(frame : Frame) : Scope
        scope = Scope.of(frame.context)
        return scope if frame.locals.empty?

        bindings = frame.locals.select(&.name.starts_with?("typeof("))
        bindings.empty? ? scope : scope.copy_with(bindings: bindings)
      end

      private def constructed(
        call : Crystal::Call,
        evident : Syntax::Type,
        frame : Frame,
      ) : Resolution
        written = @types.resolve(evident, scope_in(frame))
        return written unless Syntax::WellKnown::New.named?(call.name)

        found = result_of(call, frame)
        return found unless found.is_a?(Unknown)
        return found if written.is_a?(TypeRef) && written.is?(:tuple)

        found.reason.unresolved_name? || found.reason.free_variable? ? written : found
      end

      private def typed(
        node : Crystal::ASTNode,
        frame : Frame,
      ) : Resolution
        return constant(node, frame.context, frame.visiting) if node.is_a?(Crystal::Path)
        evident = Index::Evident.type(node)
        if evident.is_a?(Syntax::Type)
          return constructed(node, evident, frame) if node.is_a?(Crystal::Call)
          return @types.resolve(evident, scope_in(frame))
        end

        case node
        in Crystal::Var then variable(node.name, frame)
        in Crystal::InstanceVar, Crystal::ClassVar
          instance_var_types.of(node.name, frame.context, frame.visiting)
        in Crystal::Call                then result_of(node, frame)
        in Crystal::Path                then constant(node, frame.context, frame.visiting)
        in Crystal::ImplicitObj         then case_subject(frame)
        in Crystal::If, Crystal::Unless then branch_value(node, frame)
        in Crystal::Return, Crystal::Break, Crystal::Next
          TypeRef.of(:no_return)
        in Crystal::Case             then case_value(node, frame)
        in Crystal::Select           then select_value(node, frame)
        in Crystal::ExceptionHandler then rescued_value(node, frame)
        in Crystal::Assign           then type_of(node.value, frame)
        in Crystal::OpAssign         then op_assigned(node, frame)
        in Crystal::Yield            then yielded_result(frame.context)
        in Crystal::SizeOf, Crystal::InstanceSizeOf, Crystal::AlignOf, Crystal::InstanceAlignOf
          TypeRef.of(:int32)
        in Crystal::RangeLiteral      then range_value(node, frame)
        in Crystal::Or                then or_value(node, frame)
        in Crystal::And               then and_value(node, frame)
        in Crystal::ArrayLiteral      then array_value(node, frame)
        in Crystal::HashLiteral       then hash_literal(node, frame)
        in Crystal::TupleLiteral      then tuple_value(node, frame)
        in Crystal::NamedTupleLiteral then named_tuple_value(node, frame)
        in Crystal::Nop               then TypeRef.of(:nil)
        in Crystal::Splat, Crystal::DoubleSplat
          Unknown.new(:splatted, "`#{node}` spreads an unknown number of values")
        in Crystal::TypeOf      then typeof_value(node, frame)
        in Crystal::Expressions then expressions_value(node, frame)
        in Crystal::ASTNode
          Unknown.new(:inference_needed, "the type of `#{node}` is not written in the source")
        end
      end

      private def variable(
        name : String,
        frame : Frame,
      ) : Resolution
        return implicit_self(frame.context) if Syntax::WellKnown::SelfName.named?(name)
        facts = facts_for(frame.context)
        if (assigner = macro_expansions.assigning(name, frame.context, facts))
          detail = "`#{name}` is assigned by the expansion of `#{assigner}`, " \
                   "which flow does not follow"
          return Unknown.new(:macro, detail)
        end
        key = variable_key(name, frame.context)
        exits = exits_for(frame.context, frame.visiting + [key])
        steps = Flow.steps(name, frame.context.ancestors, exits, facts)
        if (local = frame.locals.find(&.name.==(name)))
          uncarried = steps.reject { |step| step.is_a?(Flow::Reassigned) && step.carried }
          return narrow(local.value, name, uncarried, frame)
        end
        return key.cycle if frame.visiting.includes?(key)

        if (captured = captured(name, frame))
          return captured
        end

        if (inner = shadowing_block(name, frame.context))
          from_block = block_parameter(name, frame.visited(key))
          if from_block
            inner_steps = Flow.steps(name, frame.context.ancestors[inner..], exits, facts)
            return narrow(from_block, name, inner_steps, frame)
          end
        end
        if (enclosing = enclosing_rescue(name, frame.context))
          handler, rescued = enclosing
          inner_steps = Flow.steps(name, frame.context.ancestors[handler..], exits, facts)
          bound = rescued_type(rescued, frame.context)
          return narrow(bound, name, inner_steps, frame)
        end

        base = declared_variable(name, frame, steps)
        narrow(base, name, steps, frame)
      end

      private def captured(
        name : String,
        frame : Frame,
      ) : Resolution?
        index = frame.context.proc_index
        definition = frame.context.def_node
        return unless index && definition
        return if definition.args.any?(&.name.==(name))
        return if shadowing_block(name, frame.context).try(&.> index)

        inner = facts_of(definition.body)
        return unless inner.assigned(name).empty? && inner.declaration(name).nil?
        return if inner.rescued(name)

        outer = frame.context.outside_proc(index)
        if reassigned_after?(name, frame.context.ancestors[index], outer)
          return Unknown.new(
            :inference_needed, "#{name} is captured by a proc and reassigned after it"
          )
        end

        variable(name, frame.within(outer))
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
        @memos.facts[body.object_id] ||= BodyFacts.of(body)
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
        frame : Frame,
      ) : Resolution
        steps.reduce(base) do |current, step|
          case step
          in Flow::Assigned
            narrow_assigned(current, step, name, frame)
          in Flow::Branched
            branched(current, step, name, frame)
          in Flow::Reassigned
            narrow_reassigned(current, step, name, frame)
          in Flow::OrAssigned
            narrow_or_assigned(current, step, name, frame)
          in Flow::Truthy, Flow::IsA, Flow::RespondsTo
            @narrowing.apply(current, step, frame.context)
          in Flow::Declared
            declared_step(step, name, frame)
          end
        end
      end

      private def variable_key(name : String, context : Syntax::Context) : VariableVisit
        owner = context.blocks.last? || context.def_node
        VariableVisit.new(name, owner.try(&.object_id))
      end

      private def declared_variable(
        name : String,
        frame : Frame,
        steps : Array(Flow::Step),
      ) : Resolution
        definition = frame.context.def_node
        body = definition ? definition.body : frame.context.ancestors.first?
        unless body
          return Unknown.new(:no_annotation, "#{name} is outside any method or script")
        end

        facts = facts_of(body)
        rescued = facts.rescued(name)
        from_active_rescue(rescued, frame.context) ||
          from_parameter(name, definition, frame.context) ||
          from_block_arg(name, definition, frame.context) ||
          from_declaration(name, facts, frame.context) ||
          from_block_parameter(name, frame) ||
          from_rescue(rescued, frame.context) ||
          from_assignments(name, facts, frame, steps)
      end

      private def branched(
        current : Resolution,
        step : Flow::Branched,
        name : String,
        frame : Frame,
      ) : Resolution
        return current if !step.assigns && (current.is_a?(TypeVar) || current.is_a?(Unknown))

        exits = exits_for(frame.context, frame.visiting)
        results = Array(Resolution).new(step.branches.size)
        step.branches.each do |branch|
          body = branch.body
          entry = Flow.new(name, exits, facts_for(frame.context))
          next if body && entry.exits?(body, step.within)

          entry.collect(step.cond, branch.positive, step.within)
          start = narrow(current, name, entry.steps, frame)
          if body && !body.is_a?(Crystal::Nop)
            inner = Flow.new(name, exits, facts_for(frame.context))
            inner.walk(body, step.within + [body])
            start = narrow(start, name, inner.steps, frame)
          end
          results << start
        end
        return TypeRef.of(:no_return) if results.empty?

        @unions.union(results)
      end

      private def value_type(value : Crystal::ASTNode, locals : Array(Binding)) : Resolution?
        return unless locals.empty?

        @memos.typed_values[value.object_id]?
      end

      private def remember_value(
        value : Crystal::ASTNode,
        typed : Resolution,
        locals : Array(Binding),
      ) : Resolution
        @memos.typed_values[value.object_id] = typed if locals.empty? && !unsettled?(typed)
        typed
      end

      private def constructed_result(
        call : Crystal::Call,
        context : Syntax::Context,
        visiting : Array(Visit),
      ) : Resolution
        key = ConstructionKey.new(CallKey.of(call, context), visiting)
        cached = @memos.constructions[key]?
        return cached.result if cached && cached.context.same_as?(context)

        exhausted = @depth_exhausted
        result = computed_result(call, Frame.new(context, Array(Binding).new, visiting))
        if exhausted == @depth_exhausted && !unsettled?(result)
          stored = ConstructionKey.new(key.call, visiting.dup)
          @memos.constructions[stored] = CachedCall.new(call, context.copy, result)
        end
        result
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

        known = UnionRef.members_of(seed)
        grown = UnionRef.members_of(typed).reject { |member| known.includes?(member) }
        return typed if grown.empty?

        Unknown.new(
          :cycle,
          "#{name} widens on every pass (#{seed} then #{typed}); declare its type",
        )
      end

      private def looped?(step : Flow::Reassigned, item : Reassignment) : Bool
        return true if step.carried

        statement = step.within.last?
        return true if statement.is_a?(Crystal::While) || statement.is_a?(Crystal::Until)

        item.path.any? do |node|
          node.is_a?(Crystal::While) || node.is_a?(Crystal::Until) || node.is_a?(Crystal::Block)
        end
      end

      private def seeded(locals : Array(Binding), name : String, seed : Resolution) : Array(Binding)
        return locals if seed.is_a?(Unknown)

        locals.reject(&.name.==(name)) << Binding.new(name, seed)
      end

      private def elements(
        nodes : Array(Crystal::ASTNode),
        frame : Frame,
        & : Resolution -> Resolution
      ) : Resolution
        if nodes.empty?
          return Unknown.new(:no_annotation, "an empty literal needs `of T` to state its type")
        end

        typed = Array(Resolution).new(nodes.size)
        nodes.each { |element| typed << type_of(element, frame) }
        inner = @unions.union(typed)
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

      private def enclosing_rescue(
        name : String,
        context : Syntax::Context,
      ) : {Int32, Crystal::Rescue}?
        (context.ancestors.size - 1).downto(0) do |index|
          node = context.ancestors[index]
          return {index, node} if node.is_a?(Crystal::Rescue) && node.name == name
        end
      end

      private def rescued_type(rescued : Crystal::Rescue, context : Syntax::Context) : Resolution
        types = rescued.types
        return TypeRef.of(:exception) unless types

        scope = Scope.of(context)
        @unions.union(types.map { |type| @types.resolve(Syntax::TypeReader.read(type), scope) })
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

      private def implicit_receiver(call : Crystal::Call, context : Syntax::Context) : Resolution
        scope = yield_scope(context)
        return implicit_target(call, context) if scope.is_a?(Unscoped) || scope.is_a?(Unknown)

        defs = @methods.named_on(scope, call.name, context.path)
        defs.empty? ? implicit_target(call, context) : scope
      end

      private def implicit_target(call : Crystal::Call, context : Syntax::Context) : Resolution
        this = implicit_self(context)
        return this unless this.is_a?(TypeRef) && @methods.extends_itself?(this.identity)
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
        defs = @methods.dispatch(target, shape)
        if defs.empty?
          return @methods.missing(block_call.name, target)
        end

        scoped = defs.select(&.with_yield)
        return Unscoped.new if scoped.empty?

        @unions.union(scoped.map { |entry| with_scope(entry, target, shape.types) })
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
        enclosing = owner.is_a?(Index::Identity) ? [owner] : Array(Index::Identity).new
        sites = Syntax::YieldSites.in(
          definition, enclosing, entry.free_vars, entry.path, @workspace.crystal_version
        )
        visiting = Array(Visit){DefVisit.of(entry)}
        scopes = Array(Resolution).new
        sites.each do |site|
          expression = site.node.scope
          next unless expression

          if expression.is_a?(Crystal::Var) && Syntax::WellKnown::SelfName.named?(expression.name)
            scopes << owning(entry, receiver)
          else
            scopes << type_of(expression, site.context, visiting, Array(Binding).new)
          end
        end
        if scopes.empty?
          return Unknown.new(:no_annotation, "#{entry.qualified} yields without a scope")
        end

        scope = return_scope(entry, receiver, arguments, Site::NONE)
        scope.is_a?(Unknown) ? @unions.union(scopes) : @unions.rebind(@unions.union(scopes), scope)
      end

      private def loop_result(block : Crystal::Block, site : Site) : Resolution
        values = break_values(block, site)
        values.empty? ? TypeRef.of(:no_return) : @unions.union(values)
      end

      private def break_values(block : Crystal::Block, site : Site) : Array(Resolution)
        escape_values(Escapes.in(block).breaks, block, site.frame)
      end

      private def escape_values(
        found : Array(Escapes::Found),
        block : Crystal::Block,
        frame : Frame,
      ) : Array(Resolution)
        found.map do |escape|
          exp = escape.node.exp
          next TypeRef.of(:nil).as(Resolution) unless exp

          inside = frame.context.inside(block)
          escape.ancestors.each { |ancestor| inside = inside.inside(ancestor) }
          type_of(exp, frame.within(inside.inside(escape.node, exp)))
        end
      end

      private def implicit_self(context : Syntax::Context) : Resolution
        owner = context.owner
        return ProgramRef.new if owner.is_a?(Index::TopLevel)

        this = TypeRef.new(owner, Array(Resolution).new)
        index = context.proc_index
        return implicit_self(context.outside_proc(index)) if index

        definition = context.def_node
        return (context.instance_code? ? this : MetaRef.new(this)) unless definition

        definition.receiver ? MetaRef.new(this) : this
      end

      private def enum_base(receiver : TypeRef) : Resolution
        namespace = @workspace.namespaces(receiver.identity).find(&.is_a?(Index::EnumNamespace))
        base = namespace.is_a?(Index::EnumNamespace) ? namespace.base_type : nil
        return TypeRef.of(:int32) unless namespace && base.is_a?(Syntax::Type)

        @types.resolve_lexically(base, Scope.of(receiver.identity.parent, namespace.path))
      end

      private def compacted(receiver : TypeRef) : Resolution
        element = receiver.arguments[0]?
        return receiver unless element.is_a?(UnionRef)

        kept = element.members.reject { |member| member.is_a?(TypeRef) && member.is?(:nil) }
        TypeRef.of(:array, [@unions.union(kept)] of Resolution)
      end

      private def forwarded(
        entry : Index::Def,
        target : Crystal::ASTNode,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        owner = entry.owner
        enclosing = owner.is_a?(Index::Identity) ? [owner] : Array(Index::Identity).new
        context = Syntax::Context.new(enclosing, Array(String).new, nil, entry.path, true)
        visit = DefVisit.of(entry)
        return visit.cycle if site.visiting.includes?(visit)

        visiting = site.visiting + [visit]
        delegate = type_of(target, context, visiting, Array(Binding).new)
        return delegate if delegate.is_a?(Unknown)

        shape = Methods::CallShape.of_types(entry.name, arguments, !site.block.nil?)
        dispatch.result(delegate, shape, Site.new(site.block, site.frame.with_visiting(visiting)))
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
        bind_parameter_types(entry, arguments, bindings, scope)
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
        visiting : Array(Visit),
      ) : Resolution
        scope = Scope.of(context)
        if path.names.size == 1 && !path.global? && scope.type_vars.includes?(path.names[0])
          return MetaRef.new(TypeVar.new(path.names[0]))
        end
        named = Syntax::Named.new(path.names, path.global?)
        if (builtin = Builtins.constant_type(path.names.join("::")))
          return @types.resolve(builtin, Scope::TOP)
        end
        located = @types.locate_any(named, scope)
        if located.is_a?(Unknown)
          inherited = @types.resolve(named, scope)
          return inherited.is_a?(Unknown) ? located : @unions.metaclass_of(inherited)
        end

        constants = @workspace.constants(located)
        return @unions.metaclass_of(@types.resolve(named, scope)) if constants.empty?
        visit = ConstantVisit.new(located)
        return visit.cycle if visiting.includes?(visit)

        @unions.union(constants.map { |entry| constant_type(entry, visiting + [visit]) })
      end

      private def placeholder?(expression : Crystal::ASTNode) : Bool
        expression.is_a?(Crystal::Call) && expression.obj.nil? && expression.name == "uninitialized"
      end

      private def constant_type(entry : Index::Constant, visiting : Array(Visit)) : Resolution
        owner = entry.identity.parent
        if owner.is_a?(Index::Identity) && @workspace.enum?(owner)
          return TypeRef.new(owner, Array(Resolution).new)
        end
        owner_scope = Scope.of(owner, entry.path)
        expression = entry.expression
        enclosing = owner.is_a?(Index::Identity) ? [owner] : Array(Index::Identity).new
        context = Syntax::Context.new(enclosing, Array(String).new, nil, entry.path)
        if expression.is_a?(Crystal::Path)
          return type_of(expression, context, visiting, Array(Binding).new)
        end

        type = entry.type
        return @types.resolve(type, owner_scope) if type.is_a?(Syntax::Type)
        unless expression
          return Unknown.new(:no_annotation, "#{entry.name} has no value to type")
        end
        if Index::MacroTarget.generated?(entry.path) && placeholder?(expression)
          detail = "#{entry.name} is set by a macro whose value the helper did not export"
          return Unknown.new(:macro, detail)
        end

        type_of(expression, context, visiting, Array(Binding).new)
      end

      private def block_parameter(
        name : String,
        frame : Frame,
      ) : Resolution?
        frame.context.blocks.reverse_each do |call|
          block = call.block
          next unless block
          index = block.args.index(&.name.==(name))
          unpacked = index ? nil : BlockInputs.unpacked_position(block, name)
          index ||= unpacked.try(&.parameter_index)
          next unless index

          collected = BlockInputs.collected(block, index, name)
          return collected if collected

          outer = outside(call, frame.context)
          receiver = of_call(call, frame.within(outer))
          return receiver if receiver.is_a?(Unknown)

          input = block_inputs.remembered(call, index) || begin
            shape = shape_of(call, frame.within(outer))
            computed = block_inputs.of(receiver, shape, index, block.args.size)
            if frame.locals.empty? && !unsettled?(computed)
              block_inputs.remember(call, index, computed)
            end
            computed
          end
          return input unless unpacked

          return block_inputs.unpacked_element(input, unpacked.path, name)
        end
        nil
      end

      private def literal_collection(
        node : Crystal::ArrayLiteral,
        context : Syntax::Context,
      ) : Index::Identity
        name = node.name
        array = CoreType::Array.identity
        return array unless name

        resolved = @types.resolve(Syntax::TypeReader.read(name), Scope.of(context))
        resolved.is_a?(TypeRef) ? resolved.identity : array
      end

      private def bind_block(
        entry : Index::Def,
        site : Site,
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        restriction = block_inputs.restriction_of(entry)
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

        resolved = restriction.inputs.map { |input| @types.resolve(input, scope) }
        inputs = block_inputs.splatted(resolved, block)
        locals = site.locals.dup
        block.args.each_with_index do |argument, index|
          input = BlockInputs.collected(block, index, argument.name) || inputs[index]?
          next unless input

          unpacked = block.unpacks.try(&.[index]?)
          next locals << Binding.new(argument.name, input) unless unpacked

          block_inputs.bind_unpacked(input, unpacked, locals)
        end
        body = block.body
        nexts = Escapes.in(block).nexts
        inner = site.frame.with_locals(locals)
        results = escape_values(nexts, block, inner)
        results << type_of(body, inner.inside(block, body))
        Unify.bind(output, @unions.union(results), free_vars, bindings, @types, scope)
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

        proc = type_of(passed, site.frame)
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
            @types.resolve(typed, Scope.of(site.context))
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

        shape = Methods::CallShape.of_types(pointer.name, arguments, false)
        dispatch.result(receiver, shape)
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
        bind_splat(entry, positional.size, arguments, free_vars, bindings, scope)
      end

      private def bind_splat(
        entry : Index::Def,
        offset : Int32,
        arguments : Array(Resolution),
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        restriction = entry.parameters.find(&.kind.splat?).try(&.restriction)
        return unless restriction.is_a?(Syntax::Splat)

        Unify.bind(restriction.inner, packed(arguments, offset), free_vars, bindings, @types, scope)
      end

      private def packed(arguments : Array(Resolution), offset : Int32) : Resolution
        spread = arguments.first(offset).find do |argument|
          argument.is_a?(Unknown) && argument.reason.splatted?
        end
        return spread if spread

        members = arguments.skip(offset)
        unknown = members.find(&.is_a?(Unknown))
        return unknown if unknown

        TypeRef.of(:tuple, members)
      end

      private def bind_parameter_types(
        entry : Index::Def,
        arguments : Array(Resolution),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        entry.parameters.select(&.kind.positional?).each_with_index do |parameter, index|
          argument = arguments[index]? || defaulted(parameter, scope)
          bindings << Binding.new("typeof(#{parameter.name})", argument) if argument
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

      private def enum_each(receiver : Resolved, scope : Scope) : Resolution?
        return unless receiver.is_a?(MetaRef)

        enum_type = receiver.of
        return unless enum_type.is_a?(TypeRef)

        namespace = @workspace.namespaces(enum_type.identity).find(&.is_a?(Index::EnumNamespace))
        flags = namespace.is_a?(Index::EnumNamespace) && namespace.flags
        members = @workspace.constants_of(enum_type.identity).reject do |constant|
          flags && constant.identity.last.in?("None", "All")
        end
        return TypeRef.of(:nil) if members.empty?

        scope.bound("U")
      end

      private def nil_asserted?(receiver : Resolved, arguments : Array(Resolution)) : Bool
        return false unless receiver.is_a?(TypeRef) && receiver.is?(:nil)

        expectation = arguments[0]?
        expectation.is_a?(TypeRef) && expectation.identity == BE_NIL_EXPECTATION
      end

      private def declared_step(
        step : Flow::Declared,
        name : String,
        frame : Frame,
      ) : Resolution
        declared = Syntax::TypeReader.read(step.restriction)
        restriction = @types.resolve(declared, Scope.of(frame.context))
        value = step.value
        return restriction unless value && restriction.is_a?(Resolved)

        key = variable_key(name, frame.context)
        typed = type_of(value, frame.at(step.within).visited(key))
        return restriction unless typed.is_a?(Resolved) && @methods.admits?(restriction, typed)

        typed
      end

      private def parent_call(
        call : Crystal::Call,
        shape : Methods::CallShape,
        definition : Crystal::Def,
      ) : Methods::CallShape
        given = call.has_parentheses? ? shape.given : definition.args.size
        Methods::CallShape.new(definition.name, given, shape.block?, shape.arguments, shape.named)
      end

      private def computed_result(
        call : Crystal::Call,
        frame : Frame,
      ) : Resolution
        return TypeRef.of(:bool) if Receiver.chained_comparison?(call)

        case macro_precedence(call, frame.context)
        in .macro?
          annotated = macro_expansions.inside_annotation(call, frame.context)
          return annotated || macro_expansions.expansion(call, frame)
        in .undecided?
          detail = "`#{call.name}` is a macro or a def depending on arguments not known here"
          return Unknown.new(:macro, detail)
        in .def?
        end

        receiver = of_call(call, frame)
        return receiver if receiver.is_a?(Unknown)
        if receiver.is_a?(TypeRef) && receiver.is?(:tuple)
          element = tuple_element_at(receiver, call)
          return element if element
        end
        if receiver.is_a?(TypeRef) && receiver.labelled?
          element = labelled_element_at(receiver, call)
          return element if element
        end

        shape = shape_of(call, frame)
        site = Site.new(
          call.block, frame, shape.named, call.block_arg
        )
        if call.obj.nil? && Syntax::WellKnown::Super.named?(call.name)
          return super_result(call, receiver, shape, site)
        end

        outcome = dispatch.result(receiver, shape, site)
        if outcome.is_a?(Unknown) && outcome.reason.unresolved_name?
          if (action = select_action(call, frame.context))
            return dispatch.result(receiver, shape_of(action, frame), site)
          end
        end
        if outcome.is_a?(Unknown)
          return macro_expansions.result(call, frame, outcome, receiver, shape)
        end

        block = call.block
        return outcome if block.nil?

        escaped = break_values(block, site)
        escaped.empty? ? outcome : @unions.union([outcome] + escaped)
      end

      private def block_inputs : BlockInputs
        @block_inputs ||= BlockInputs.new(@types, @methods, @shims, @unions, @memos, self)
      end

      private def instance_var_types : InstanceVarTypes
        @instance_var_types ||= InstanceVarTypes.new(@workspace, @types, @unions, self)
      end

      private def macro_expansions : MacroExpansions
        @macro_expansions ||= MacroExpansions.new(@workspace, @methods, @memos, self)
      end

      private def branch_value(
        node : Crystal::If | Crystal::Unless,
        frame : Frame,
      ) : Resolution
        branches = Array(Resolution).new(2)
        branches << type_of(node.then, frame.inside(node, node.then))
        branches << type_of(node.else, frame.inside(node, node.else))
        @unions.union(branches)
      end

      private def range_value(
        node : Crystal::RangeLiteral,
        frame : Frame,
      ) : Resolution
        bounds = Array(Resolution).new(2)
        bounds << type_of(node.from, frame)
        bounds << type_of(node.to, frame)
        bounds.find(&.is_a?(Unknown)) || TypeRef.of(:range, bounds)
      end

      private def or_value(
        node : Crystal::Or,
        frame : Frame,
      ) : Resolution
        left = type_of(node.left, frame.inside(node, node.left))
        right = type_of(node.right, frame.inside(node, node.right))
        @unions.union([@narrowing.truthy(left), right] of Resolution)
      end

      private def and_value(
        node : Crystal::And,
        frame : Frame,
      ) : Resolution
        left = type_of(node.left, frame.inside(node, node.left))
        right = type_of(node.right, frame.inside(node, node.right))
        @unions.union([@narrowing.falsey(left), right] of Resolution)
      end

      private def array_value(
        node : Crystal::ArrayLiteral,
        frame : Frame,
      ) : Resolution
        collection = literal_collection(node, frame.context)
        elements(node.elements, frame) do |inner|
          TypeRef.new(collection, [inner] of Resolution)
        end
      end

      private def tuple_value(
        node : Crystal::TupleLiteral,
        frame : Frame,
      ) : Resolution
        members = Array(Resolution).new(node.elements.size)
        node.elements.each { |element| members << type_of(element, frame) }
        members.find(&.is_a?(Unknown)) || TypeRef.of(:tuple, members)
      end

      private def named_tuple_value(
        node : Crystal::NamedTupleLiteral,
        frame : Frame,
      ) : Resolution
        members = Array(Resolution).new(node.entries.size)
        node.entries.each { |entry| members << type_of(entry.value, frame) }
        unknown = members.find(&.is_a?(Unknown))
        unknown || TypeRef.new(CoreType::NamedTuple.identity, members, node.entries.map(&.key))
      end

      private def typeof_value(
        node : Crystal::TypeOf,
        frame : Frame,
      ) : Resolution
        members = Array(Resolution).new(node.expressions.size)
        node.expressions.each { |inner| members << type_of(inner, frame) }
        members.find(&.is_a?(Unknown)) || @unions.metaclass_of(@unions.union(members))
      end

      private def expressions_value(
        node : Crystal::Expressions,
        frame : Frame,
      ) : Resolution
        last = node.expressions.last?
        return TypeRef.of(:nil) unless last

        type_of(last, frame.inside(node, last))
      end

      private def narrow_assigned(
        current : Resolution,
        step : Flow::Assigned,
        name : String,
        frame : Frame,
      ) : Resolution
        key = variable_key(name, frame.context)
        bound = seeded(frame.locals, name, current)
        seeded_frame = frame.at(step.within).visited(key).with_locals(bound)
        value_type(step.value, frame.locals) ||
          remember_value(step.value, type_of(step.value, seeded_frame), frame.locals)
      end

      private def narrow_reassigned(
        current : Resolution,
        step : Flow::Reassigned,
        name : String,
        frame : Frame,
      ) : Resolution
        key = variable_key(name, frame.context)
        values = Array(Resolution).new(step.values.size + 1)
        values << current unless step.definite
        seeded_frame = frame.visited(key).with_locals(seeded(frame.locals, name, current))
        step.values.each do |item|
          inner = seeded_frame.at(step.within + item.path)
          typed = value_type(item.value, frame.locals) ||
                  remember_value(item.value, type_of(item.value, inner), frame.locals)
          values << (looped?(step, item) ? settled(name, current, item.value, typed) : typed)
        end
        @unions.union(values)
      end

      private def narrow_or_assigned(
        current : Resolution,
        step : Flow::OrAssigned,
        name : String,
        frame : Frame,
      ) : Resolution
        key = variable_key(name, frame.context)
        bound = seeded(frame.locals, name, current)
        seeded_frame = frame.at(step.within).visited(key).with_locals(bound)
        typed = value_type(step.value, frame.locals) ||
                remember_value(step.value, type_of(step.value, seeded_frame), frame.locals)
        present = @narrowing.truthy(current)
        return typed if present.is_a?(TypeRef) && present.is?(:nil)

        @unions.union([present, typed] of Resolution)
      end

      private def from_active_rescue(
        rescued : Crystal::Rescue?,
        context : Syntax::Context,
      ) : Resolution?
        return unless rescued && context.ancestors.any?(&.same?(rescued))

        rescued_type(rescued, context)
      end

      private def from_rescue(rescued : Crystal::Rescue?, context : Syntax::Context) : Resolution?
        rescued_type(rescued, context) if rescued
      end

      private def from_parameter(
        name : String,
        definition : Crystal::Def?,
        context : Syntax::Context,
      ) : Resolution?
        return unless definition
        parameter = definition.args.find(&.name.==(name))
        return unless parameter

        restriction = parameter.restriction
        unless restriction
          return Unknown.new(:no_annotation, "parameter #{name} has no type restriction")
        end
        typed = @types.resolve(Syntax::TypeReader.read(restriction), Scope.of(context))
        return typed if typed.is_a?(Unknown)
        return typed unless definition.splat_index == definition.args.index(parameter)

        TypeRef.of(:tuple, [typed] of Resolution)
      end

      private def from_block_arg(
        name : String,
        definition : Crystal::Def?,
        context : Syntax::Context,
      ) : Resolution?
        return unless definition
        block_arg = definition.block_arg
        return unless block_arg && block_arg.name == name

        restriction = block_arg.restriction
        unless restriction
          return Unknown.new(:no_annotation, "block parameter #{name} has no type restriction")
        end

        @types.resolve(Syntax::TypeReader.read(restriction), Scope.of(context))
      end

      private def from_declaration(
        name : String,
        facts : BodyFacts,
        context : Syntax::Context,
      ) : Resolution?
        declaration = facts.declaration(name)
        return unless declaration

        restriction = Syntax::TypeReader.read(declaration.declared_type)
        @types.resolve(restriction, Scope.of(context))
      end

      private def from_block_parameter(
        name : String,
        frame : Frame,
      ) : Resolution?
        key = variable_key(name, frame.context)
        return key.cycle if frame.visiting.includes?(key)

        block_parameter(name, frame.visited(key))
      end

      private def from_assignments(
        name : String,
        facts : BodyFacts,
        frame : Frame,
        steps : Array(Flow::Step),
      ) : Resolution
        assignments = facts.assigned(name)
        if assignments.empty?
          return Unknown.new(
            :no_annotation, "#{name} is not a parameter and is never assigned here"
          )
        end
        if steps.any? { |step| Narrowing.assigning?(step) }
          return TypeRef.of(:nil)
        end

        assignments = same_block(assignments, facts.reassigned(name), frame.context)
        assigned = Array(Resolution).new(assignments.size)
        deferred = Array(Crystal::ASTNode).new
        key = variable_key(name, frame.context)
        assignments.each do |value|
          typed = value_type(value, frame.locals) ||
                  remember_value(value, type_of(value, frame.visited(key)), frame.locals)
          if typed.is_a?(Unknown) && typed.reason.cycle?
            deferred << value
          else
            assigned << typed
          end
        end
        return @unions.union(assigned) if deferred.empty?

        seed = @unions.union(assigned)
        return Unknown.new(:cycle, name) if seed.is_a?(Unknown)

        seeded_frame = frame.visited(key).with_locals(seeded(frame.locals, name, seed))
        deferred.each do |value|
          typed = type_of(value, seeded_frame)
          assigned << settled(name, seed, value, typed)
        end
        @unions.union(assigned)
      end
    end
  end
end
