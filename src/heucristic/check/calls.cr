require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../index/accessor"
require "../resolve/methods"
require "../resolve/types"
require "../resolve/scope"
require "../resolve/receiver"
require "./finding"
require "./settled"
require "./with_yield"
require "./macro_uses"
require "../syntax/well_known"
require "../index/synthesized"
require "../index/macro_hook"

module Heucristic
  module Check
    struct Calls
      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @settled : Settled,
      ) : Nil
      end

      def run(sites : Index::Sites) : Array(Finding)
        findings = Array(Finding).new
        sites.calls.each { |site| check(site, sites.text, findings) }
        findings
      end

      private def check(
        site : Syntax::Uses::CallSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        call = site.call
        return if Syntax::WellKnown.from_name(call.name).try(&.unchecked?)
        return unless @workspace.macros(call.name).empty?
        location = call.name_location
        return unless location
        return if within_macro_arguments?(site.context.ancestors)
        return if select_condition?(call, site.context.ancestors)

        receiver = @receiver.of_call(call, site.context)
        defs = definitions(receiver, call, site.context)
        return unless defs

        start = Document::Point.from(location)
        span = text.span(start, start.advance(call.name_size))
        return unless span.is_a?(Document::Span)

        if defs.empty?
          findings << Finding.new(:undefined_method, undefined(call, receiver), span)
          return
        end

        shape(defs, call, receiver, span, findings)
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
          target = @receiver.of_call(block_call, context)
          next true if target.is_a?(Resolve::Unknown)

          defs = @methods.lookup(target, @receiver.shape_of(block_call, context))
          defs.empty? || defs.any? { |entry| WithYield.in?(entry) }
        end
      end

      private def within_macro_arguments?(ancestors : Array(Crystal::ASTNode)) : Bool
        ancestors.each_with_index.any? do |node, index|
          next false unless node.is_a?(Crystal::Call) && node.obj.nil? && macro_like?(node.name)

          block = node.block
          block.nil? || !ancestors[index + 1]?.try(&.same?(block))
        end
      end

      private def macro_like?(name : String) : Bool
        !Index::Accessor.from_name(name).nil? || !Index::Synthesized.from_name(name).nil? ||
          !@workspace.macros(name).empty?
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
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return if call.args.any?(Crystal::Splat | Crystal::DoubleSplat)
        return unless call.named_args.nil? || call.named_args.try(&.empty?)
        return if call.block_arg
        return if defs.any? { |entry| keyword_parameters?(entry) }
        return if Syntax::WellKnown::New.named?(call.name) && !constructor_known?(receiver)

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

        return if fitting.any? { |entry| WithYield.macro_body?(entry) }
        given = !call.block.nil?
        return unless fitting.all? { |entry| entry.yields != given }

        message = String.build do |io|
          io << '\'' << qualified << "' is " << (given ? "not " : "")
          io << "expected to be invoked with a block, but " << (given ? "a block" : "no block")
          io << " was given"
        end
        findings << Finding.new(:block_mismatch, message, span)
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

        levels = @methods.levels(of.name)
        return false if @workspace.namespaces(of.name).any?(Index::EnumNamespace)
        return false if levels.any? { |level| generated_defs?(level) }

        Index::MacroHook.values.none? do |hook|
          next false unless hook.generates_defs?

          @workspace.macros(hook.macro_name).any? { |entry| levels.includes?(entry.owner) }
        end
      end

      private def generated_defs?(level : String) : Bool
        @workspace.defs_of(level).any?(&.path.==(Settled::GENERATED))
      end

      private def expected(arity : Index::Arity) : String
        return "#{arity.required}+" if arity.splat
        return arity.required.to_s if arity.optional.zero?

        "#{arity.required}..#{arity.required + arity.optional}"
      end
    end
  end
end
