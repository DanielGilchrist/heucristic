require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../index/accessor"
require "../resolve/methods"
require "../resolve/types"
require "../syntax/type_reader"
require "../resolve/scope"
require "../resolve/receiver"
require "./finding"
require "./outcome"
require "./skip"
require "./settled"
require "./macro_uses"
require "../syntax/well_known"
require "../index/synthesized"
require "../index/evident"
require "./macro_arguments"
require "./fit"
require "../index/macro_hook"

module Heucristic
  module Check
    class Calls
      record Virtual, defs : Array(Index::Def)

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @settled : Settled,
      ) : Nil
        @dsl_blocks = Hash(UInt64, Bool).new
        @mixed_in = Hash(String, Array(Index::Def)).new
      end

      def run(sites : Index::Sites) : Outcome
        findings = Array(Finding).new
        checked = 0
        skips = Hash(Skip, Int32).new(0)
        examples = Hash(Skip, String).new
        unknown = Hash(String, Int32).new(0)
        unsettled = Hash(String, Int32).new(0)
        sites.calls.each do |site|
          skip = check(site, sites.text, findings, unknown, unsettled)
          if skip
            skips[skip] += 1
            examples[skip] ||= "#{sites.path}:#{site.call.name_location.try(&.line_number)}"
          else
            checked += 1
          end
        end
        Outcome.new(findings, checked, skips, examples, unknown, unsettled)
      end

      private def check(
        site : Syntax::Uses::CallSite,
        text : Document::Text,
        findings : Array(Finding),
        unknown : Hash(String, Int32),
        unsettled : Hash(String, Int32),
      ) : Skip?
        call = site.call
        location = call.name_location
        return Skip::NoLocation unless location
        return Skip::MacroInvocation unless @workspace.macros(call.name).empty?
        return Skip::MacroArguments if MacroArguments.within?(site.context.ancestors, @workspace)
        return Skip::SelectCondition if select_condition?(call, site.context.ancestors)
        return Skip::ChainedComparison if Resolve::Receiver.chained_comparison?(call)

        start = Document::Point.from(location)
        span = text.span(start, start.advance(call.name_size))
        return Skip::NoLocation unless span.is_a?(Document::Span)

        known = Syntax::WellKnown.from_name(call.name)
        if known.try(&.unchecked?)
          return orphan(known, call, site.context, span, findings) ? nil : Skip::OrphanOutsideDef
        end

        receiver = @receiver.of_call(call, site.context)
        if call.obj.is_a?(Crystal::ImplicitObj)
          receiver = narrowed_subject(receiver, call, site.context)
        end
        return if abstract_instantiation(known, call, receiver, span, findings)
        if receiver.is_a?(Resolve::Unknown)
          unknown[receiver.to_s] += 1
          return Skip::ReceiverUnknown
        end
        if receiver.is_a?(Resolve::UnionRef)
          return Skip::ImplicitObject if call.obj.nil?

          return union_receiver(receiver, call, span, findings)
        end

        defs = definitions(receiver, call, site.context)
        if defs.is_a?(Skip)
          unsettled[described(receiver)] += 1 if defs.type_unsettled?
          return defs
        end
        if defs.is_a?(Virtual)
          return unless defs.defs.empty?

          findings << Finding.new(:undefined_method, undefined(call, receiver), span)
          return
        end

        if defs.empty?
          findings << Finding.new(:undefined_method, undefined(call, receiver), span)
          return
        end
        return if visibility(defs, call, receiver, site.context, span, findings)

        shape(defs, call, receiver, site.context, span, findings)
        nil
      end

      private def visibility(
        defs : Array(Index::Def),
        call : Crystal::Call,
        receiver : Resolve::Resolution,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Bool
        obj = call.obj
        return false if obj.nil?
        return false if obj.is_a?(Crystal::Var) && Syntax::WellKnown::SelfName.named?(obj.name)

        if defs.all?(&.visibility.private?)
          message = "private method '#{call.name}' called for #{described(receiver)}"
          findings << Finding.new(:private_call, message, span)
          return true
        end
        return false unless defs.all?(&.visibility.protected?)
        return false unless receiver.is_a?(Resolve::TypeRef)
        return false unless protected_from_outside?(receiver.name, context.owner)

        message = "protected method '#{call.name}' called for #{described(receiver)}"
        findings << Finding.new(:protected_call, message, span)
        true
      end

      private def protected_from_outside?(receiver : String, caller : Index::Owner) : Bool
        return true if caller.is_a?(Index::TopLevel)
        return false if caller == receiver
        return false if @methods.levels(caller).includes?(receiver)
        return false if @methods.levels(receiver).includes?(caller)

        receiver_root = receiver.partition("::")[0]
        caller_root = caller.partition("::")[0]
        receiver_root != caller_root
      end

      private def orphan(
        known : Syntax::WellKnown?,
        call : Crystal::Call,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Bool
        return false unless known && call.obj.nil?
        definition = context.def_node
        owner = context.owner
        return false unless definition && owner.is_a?(String)
        return false if Syntax::WellKnown::Initialize.named?(definition.name)
        return false unless @settled.declared?(owner)

        metaclass = !definition.receiver.nil?
        case known
        in .super?
          levels = @methods.levels(owner)
          above = levels[1..]
          return false if above.empty?

          found = @workspace.named(definition.name).any? do |entry|
            entry.receiver.metaclass? == metaclass && above.includes?(entry.owner)
          end
          return true if found

          top = above.reverse.find { |level| superclass_level?(level) } || above.last
          message = "undefined method '#{definition.name}' for #{top}"
          findings << Finding.new(:no_superclass_method, message, span)
        in .previous_def?
          earlier = @workspace.named(definition.name).count do |entry|
            entry.receiver.metaclass? == metaclass && entry.owner == owner
          end
          return true if earlier > 1

          message = "there is no previous definition of '#{definition.name}'"
          findings << Finding.new(:no_previous_def, message, span)
        in .allocate?, .new?, .initialize?, .self_name? then return false
        end
        true
      end

      private def superclass_level?(level : String) : Bool
        @settled.compiled_level?(level) &&
          @workspace.namespaces(level).any?(Index::ClassNamespace)
      end

      private def abstract_instantiation(
        known : Syntax::WellKnown?,
        call : Crystal::Call,
        receiver : Resolve::Resolution,
        span : Document::Span,
        findings : Array(Finding),
      ) : Bool
        return false unless known.try(&.new?) && call.obj.is_a?(Crystal::Path)
        return false unless receiver.is_a?(Resolve::MetaRef)
        of = receiver.of
        return false if of.is_a?(Resolve::TypeVar)
        return false unless @settled.type?(of.name)

        entry = @workspace.namespaces(of.name).select(Index::ClassNamespace).first?
        return false unless entry && entry.abstract_type

        kind = entry.kind.struct? ? "struct" : "class"
        message = "can't instantiate abstract #{kind} #{of.name}"
        findings << Finding.new(:abstract_instantiated, message, span)
        true
      end

      private def union_receiver(
        receiver : Resolve::UnionRef,
        call : Crystal::Call,
        span : Document::Span,
        findings : Array(Finding),
      ) : Skip?
        members = receiver.members.map do |member|
          return Skip::UnionMemberNotType unless member.is_a?(Resolve::TypeRef)
          return Skip::TypeUnsettled unless @settled.type?(member.name)
          return Skip::TypeHasSubclasses if @settled.extended?(member.name)

          member
        end
        missing = members.find { |member| @methods.named_on(member, call.name).empty? }
        return unless missing

        message = String.build do |io|
          io << "undefined method '" << call.name << "' for " << missing
          io << " (compile-time type is (" << receiver << "))"
        end
        findings << Finding.new(:undefined_on_member, message, span)
        nil
      end

      private def definitions(
        receiver : Resolve::Resolution,
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Array(Index::Def) | Skip | Virtual
        case receiver
        in Resolve::Unknown  then Skip::ReceiverUnknown
        in Resolve::UnionRef then Skip::UnionMemberNotType
        in Resolve::TypeVar  then Skip::ReceiverTypeVar
        in Resolve::TypeRef
          return program_definitions(call, context) if receiver.program?

          typed_definitions(receiver, receiver.name, call, context)
        in Resolve::MetaRef
          of = receiver.of
          return Skip::ReceiverTypeVar if of.is_a?(Resolve::TypeVar)

          typed_definitions(receiver, of.name, call, context)
        end
      end

      private def program_definitions(
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Array(Index::Def) | Skip
        return Skip::ProgramUnsettled unless @settled.program?
        return Skip::DslBlock if dsl_block?(context)

        found = top_level(call.name, context)
        found.concat(@methods.named_on(object_type, call.name))
        top_level_mixed_in(call.name, found)
      end

      private def top_level_mixed_in(name : String, found : Array(Index::Def)) : Array(Index::Def)
        cached = @mixed_in[name]?
        found.concat(cached || (@mixed_in[name] = mixed_in(name)))
      end

      private def mixed_in(name : String) : Array(Index::Def)
        found = Array(Index::Def).new
        @workspace.mixins_of(Index::TopLevel.new).each do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)

          resolved = @types.resolve_lexically(target, Resolve::Scope.of(Resolve::TypeRef::PROGRAM))
          next unless resolved.is_a?(Resolve::TypeRef)

          found.concat(@methods.named_on(resolved, name))
        end
        found
      end

      private def select_condition?(
        call : Crystal::Call,
        ancestors : Array(Crystal::ASTNode),
      ) : Bool
        ancestors.each_with_index.any? do |node, index|
          next false unless node.is_a?(Crystal::Select)
          branch = ancestors[index + 1]?
          next false unless branch.is_a?(Crystal::When)

          inner = ancestors[index + 2]? || call
          branch.conds.any?(&.same?(inner))
        end
      end

      private def typed_definitions(
        receiver : Resolve::Resolved,
        type : String,
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Array(Index::Def) | Skip | Virtual
        return Skip::TypeUnsettled unless @settled.type?(type)
        return virtual_definitions(receiver, type, call) if @settled.extended?(type)

        defs = @methods.named_on(receiver, call.name)
        return defs unless call.obj.nil?
        return Skip::ProgramUnsettled unless @settled.program?
        return Skip::DslBlock if dsl_block?(context)

        defs.concat(top_level(call.name, context))
        top_level_mixed_in(call.name, defs)
      end

      private def virtual_definitions(
        receiver : Resolve::Resolved,
        type : String,
        call : Crystal::Call,
      ) : Skip | Virtual
        return Skip::TypeHasSubclasses if call.obj.nil?

        defs = @methods.named_on(receiver, call.name)
        return Virtual.new(defs) unless defs.empty?

        @settled.descendants(type).each do |descendant|
          return Skip::TypeUnsettled unless @settled.type?(descendant)

          found = @methods.named_on(as_descendant(receiver, descendant), call.name)
          return Virtual.new(found) unless found.empty?
        end
        Virtual.new(defs)
      end

      private def as_descendant(
        receiver : Resolve::Resolved,
        descendant : String,
      ) : Resolve::Resolved
        typed = Resolve::TypeRef.new(descendant, Array(Resolve::Resolution).new)
        receiver.is_a?(Resolve::MetaRef) ? Resolve::MetaRef.new(typed) : typed
      end

      private def narrowed_subject(
        receiver : Resolve::Resolution,
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Resolve::Resolution
        return receiver unless receiver.is_a?(Resolve::UnionRef)
        ancestors = context.ancestors
        index = ancestors.rindex(&.is_a?(Crystal::Case))
        return receiver unless index
        enclosing = ancestors[index]
        branch = ancestors[index + 1]?
        return receiver unless enclosing.is_a?(Crystal::Case) && branch.is_a?(Crystal::When)
        return receiver unless enclosing.exhaustive?

        scope = Resolve::Scope.new(
          context.owner, context.type_vars, Array(Resolve::Binding).new, context.path
        )
        remaining = receiver.members.dup
        enclosing.whens.each do |earlier|
          break if earlier.same?(branch)

          earlier.conds.each do |cond|
            covering = covering_type(cond, scope)
            next unless covering

            remaining.reject! do |member|
              member.is_a?(Resolve::TypeRef) && covers?(covering, member.name)
            end
          end
        end
        return receiver if remaining.empty?

        remaining.size == 1 ? remaining[0] : Resolve::UnionRef.new(remaining)
      end

      private def covering_type(cond : Crystal::ASTNode, scope : Resolve::Scope) : String?
        return CoreType::Nil.type_name if cond.is_a?(Crystal::NilLiteral)
        return unless cond.is_a?(Crystal::Path) || cond.is_a?(Crystal::Generic)

        read = Syntax::TypeReader.read(cond)
        return unless read.is_a?(Syntax::Type)

        resolved = @types.resolve_lexically(read, scope)
        resolved.is_a?(Resolve::TypeRef) ? resolved.name : nil
      end

      private def covers?(covering : String, member : String) : Bool
        return true if covering == member

        chain = @types.ancestors(member)
        !chain.is_a?(Resolve::Unknown) && chain.includes?(covering)
      end

      private def top_level(name : String, context : Syntax::Context) : Array(Index::Def)
        @workspace.named(name).select do |entry|
          entry.owner.is_a?(Index::TopLevel) && entry.visible_from?(context.path)
        end
      end

      private def object_type : Resolve::TypeRef
        Resolve::TypeRef.of(:object)
      end

      private def dsl_block?(context : Syntax::Context) : Bool
        context.blocks.any? do |block_call|
          @dsl_blocks[block_call.object_id] ||= yields_with_scope?(block_call, context)
        end
      end

      private def yields_with_scope?(block_call : Crystal::Call, context : Syntax::Context) : Bool
        target = @receiver.of_call(block_call, context)
        return true if target.is_a?(Resolve::Unknown)

        defs = @methods.lookup(target, @receiver.shape_of(block_call, context))
        defs.empty? || defs.any?(&.with_yield)
      end

      private def undefined(call : Crystal::Call, receiver : Resolve::Resolution) : String
        return "undefined method '#{call.name}' for #{described(receiver)}" if call.obj

        "undefined local variable or method '#{call.name}' for #{described(receiver)}"
      end

      private def described(receiver : Resolve::Resolution) : String
        return "#{receiver.of}.class" if receiver.is_a?(Resolve::MetaRef)
        return "top-level" if receiver.is_a?(Resolve::TypeRef) && receiver.program?
        virtual = receiver.is_a?(Resolve::TypeRef) && @settled.extended?(receiver.name)
        return "#{receiver}+" if virtual

        receiver.to_s
      end

      private def shape(
        defs : Array(Index::Def),
        call : Crystal::Call,
        receiver : Resolve::Resolution,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return if call.args.any? { |arg| splat?(arg) }
        return if call.block_arg
        return if Syntax::WellKnown::New.named?(call.name) && !constructor_known?(receiver)
        keyworded = call.named_args.try { |named| !named.empty? } || false
        if keyworded || defs.any? { |entry| keyword_parameters?(entry) }
          return named_arguments(defs, call, context, span, findings)
        end

        count = call.args.size
        fitting = defs.select(&.arity.accepts?(count))
        qualified = defs[0].qualified
        if fitting.empty?
          expected = defs.map { |entry| expected(entry.arity) }.uniq!.join(", ")
          message = String.build do |io|
            io << "wrong number of arguments for '" << qualified << "' (given " << count
            io << ", expected " << expected << ')'
          end
          findings << Finding.new(:wrong_arity, message, span)
          return
        end

        return if fitting.any?(&.macro_body)
        given = !call.block.nil?
        if fitting.all? { |entry| entry.yields != given }
          message = String.build do |io|
            io << '\'' << qualified << "' is " << (given ? "not " : "")
            io << "expected to be invoked with a block, but " << (given ? "a block" : "no block")
            io << " was given"
          end
          findings << Finding.new(:block_mismatch, message, span)
          return
        end

        matching = fitting.select { |entry| entry.yields == given }
        argument_types(matching, call, context, span, findings)
      end

      private def named_arguments(
        defs : Array(Index::Def),
        call : Crystal::Call,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return unless defs.size == 1

        entry = defs[0]
        shape = @receiver.shape_of(call, context)
        complaint = shape.complaint(entry)
        return unless complaint
        return if entry.arity.splat && !complaint.starts_with?("no parameter")

        findings << Finding.new(:named_argument, complaint, span)
      end

      private def argument_types(
        fitting : Array(Index::Def),
        call : Crystal::Call,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return if fitting.empty?

        shape = @receiver.shape_of(call, context)
        fit = Fit.new(@methods)
        rejections = Array(Resolve::Methods::Rejected).new(fitting.size)
        fitting.each do |entry|
          rejected = @methods.rejected_argument(entry, shape, any_member: true)
          return unless rejected
          argument = call.args[rejected.index]?
          return if argument.is_a?(Crystal::NumberLiteral) && fit.numeric?(rejected.expected)

          rejections << rejected
        end

        qualified = fitting[0].qualified
        message = String.build do |io|
          if fitting.size == 1
            rejected = rejections[0]
            io << "expected argument #" << (rejected.index + 1) << " to '" << qualified
            io << "' to be " << rejected.expected << ", not " << rejected.actual
          else
            io << "no overload matches '" << qualified << "' with type"
            io << (shape.arguments.size == 1 ? " " : "s ")
            shape.arguments.join(io, ", ")
            io << "\n\nOverloads are:"
            fitting.each { |entry| io << "\n - " << entry.signature }
          end
        end
        findings << Finding.new(:type_mismatch, message, span)
      end

      private def splat?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::Splat) || node.is_a?(Crystal::DoubleSplat)
      end

      private def keyword_parameters?(entry : Index::Def) : Bool
        entry.parameters.any? do |parameter|
          parameter.kind.keyword? || parameter.kind.double_splat?
        end
      end

      private def constructor_known?(receiver : Resolve::Resolution) : Bool
        return false unless receiver.is_a?(Resolve::MetaRef)
        of = receiver.of
        return false if of.is_a?(Resolve::TypeVar)

        return false if @workspace.namespaces(of.name).any?(Index::EnumNamespace)

        @settled.generated_free?(of.name)
      end

      private def expected(arity : Index::Arity) : String
        return "#{arity.required}+" if arity.splat
        return arity.required.to_s if arity.optional.zero?

        "#{arity.required}..#{arity.required + arity.optional}"
      end
    end
  end
end
