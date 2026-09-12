require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../index/accessor"
require "../resolve/methods"
require "../resolve/types"
require "../resolve/scope"
require "../resolve/receiver"
require "./finding"
require "./outcome"
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
        sites.calls.each { |site| checked += 1 if check(site, sites.text, findings) }
        Outcome.new(findings, checked)
      end

      private def check(
        site : Syntax::Uses::CallSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Bool
        call = site.call
        location = call.name_location
        return false unless location
        return false unless @workspace.macros(call.name).empty?
        return false if MacroArguments.within?(site.context.ancestors, @workspace)
        return false if select_condition?(call, site.context.ancestors)
        return false if call.obj.is_a?(Crystal::ImplicitObj)
        return false if Resolve::Receiver.chained_comparison?(call)

        start = Document::Point.from(location)
        span = text.span(start, start.advance(call.name_size))
        return false unless span.is_a?(Document::Span)

        known = Syntax::WellKnown.from_name(call.name)
        return orphan(known, call, site.context, span, findings) if known.try(&.unchecked?)

        receiver = @receiver.of_call(call, site.context)
        return true if abstract_instantiation(known, call, receiver, span, findings)
        if receiver.is_a?(Resolve::UnionRef)
          return false if call.obj.nil?

          return union_receiver(receiver, call, span, findings)
        end

        defs = definitions(receiver, call, site.context)
        return false unless defs

        if defs.empty?
          findings << Finding.new(:undefined_method, undefined(call, receiver), span)
          return true
        end
        return true if visibility(defs, call, receiver, site.context, span, findings)

        shape(defs, call, receiver, site.context, span, findings)
        true
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
      ) : Bool
        members = receiver.members.map do |member|
          return false unless member.is_a?(Resolve::TypeRef)
          return false unless @settled.type?(member.name)
          return false if @settled.extended?(member.name)

          member
        end
        missing = members.find { |member| @methods.named_on(member, call.name).empty? }
        return true unless missing

        message = String.build do |io|
          io << "undefined method '" << call.name << "' for " << missing
          io << " (compile-time type is (" << receiver << "))"
        end
        findings << Finding.new(:undefined_on_member, message, span)
        true
      end

      private def definitions(
        receiver : Resolve::Resolution,
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Array(Index::Def)?
        case receiver
        in Resolve::Unknown, Resolve::UnionRef, Resolve::TypeVar then nil
        in Resolve::TypeRef
          return program_definitions(call, context) if receiver.program?

          typed_definitions(receiver, receiver.name, call, context)
        in Resolve::MetaRef
          of = receiver.of
          return if of.is_a?(Resolve::TypeVar)

          typed_definitions(receiver, of.name, call, context)
        end
      end

      private def program_definitions(
        call : Crystal::Call,
        context : Syntax::Context,
      ) : Array(Index::Def)?
        return unless @settled.program?
        return if dsl_block?(context)

        found = top_level(call.name)
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
      ) : Array(Index::Def)?
        return unless @settled.type?(type)
        return if @settled.extended?(type)

        defs = @methods.named_on(receiver, call.name)
        return defs unless call.obj.nil?
        return unless @settled.program?
        return if dsl_block?(context)

        defs.concat(top_level(call.name))
        top_level_mixed_in(call.name, defs)
      end

      private def top_level(name : String) : Array(Index::Def)
        @workspace.named(name).select(&.owner.is_a?(Index::TopLevel))
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
        rejections = Array(Resolve::Methods::Rejected).new(fitting.size)
        fitting.each do |entry|
          rejected = @methods.rejected_argument(entry, shape)
          return unless rejected
          return unless evident_argument?(call.args[rejected.index]?, rejected, context)

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

      private def evident_argument?(
        node : Crystal::ASTNode?,
        rejected : Resolve::Methods::Rejected,
        context : Syntax::Context,
      ) : Bool
        case node
        in Nil                    then false
        in Crystal::NumberLiteral then !Fit.new(@methods).numeric?(rejected.expected)
        in Crystal::Var
          rejected.actual.is_a?(Resolve::TypeRef) && declared_parameter?(node.name, context)
        in Crystal::ASTNode then Index::Evident.type(node).is_a?(Syntax::Type)
        end
      end

      private def declared_parameter?(name : String, context : Syntax::Context) : Bool
        definition = context.def_node
        return false unless definition

        definition.args.any? { |arg| arg.name == name && !arg.restriction.nil? }
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
