require "compiler/crystal/syntax"
require "../core_type"
require "../index/def"
require "../index/shims"
require "../syntax/type"
require "../syntax/yield_sites"
require "./binding"
require "./memos"
require "./methods"
require "./resolution"
require "./scope"
require "./typer"
require "./types"
require "./unions"
require "./visit"

module Heucristic
  module Resolve
    class BlockInputs
      module Typer
        include Resolve::Typer

        abstract def scope_of(
          entry : Index::Def,
          receiver : Resolved,
          arguments : Array(Resolution),
        ) : Scope | Unknown
      end

      record Unpacked, parameter_index : Int32, position : Int32

      def self.unpacked_position(block : Crystal::Block, name : String) : Unpacked?
        block.unpacks.try &.each do |index, expressions|
          position = expressions.expressions.index do |var|
            var.is_a?(Crystal::Var) && var.name == name
          end
          return Unpacked.new(index, position) if position
        end
        nil
      end

      def initialize(
        @types : Types,
        @methods : Methods,
        @shims : Index::Shims,
        @unions : Unions,
        @memos : Memos,
        @typer : Typer,
      ) : Nil
      end

      def remembered(call : Crystal::Call, index : Int32) : Resolution?
        @memos.block_inputs[{call.object_id, index}]?
      end

      def remember(call : Crystal::Call, index : Int32, input : Resolution) : Nil
        @memos.block_inputs[{call.object_id, index}] = input
      end

      def of(
        receiver : Resolved,
        shape : Methods::CallShape,
        index : Int32,
        parameters : Int32,
      ) : Resolution
        if receiver.is_a?(UnionRef)
          per_member = Array(Resolution).new(receiver.members.size)
          receiver.members.each do |member|
            per_member << if member.is_a?(Unknown)
              member
            else
              of(member, shape, index, parameters)
            end
          end
          return @unions.union(per_member)
        end

        defs = @methods.lookup(receiver, shape)
        if defs.empty? && !@methods.virtual_lookup(receiver, shape).empty?
          virtual = @methods.virtual_receivers(receiver, shape.caller_path)
          inputs = virtual.map { |below| of(below, shape, index, parameters) }
          return @unions.union(inputs)
        end
        return @methods.missing(shape.name, receiver) if defs.empty?

        inputs = Array(Resolution).new(defs.size)
        defs.each do |entry|
          inputs << for_def(entry, receiver, shape.types, index, parameters)
        end
        @unions.union(inputs)
      end

      def restriction_of(entry : Index::Def) : Syntax::Proc?
        restriction = entry.parameters.find(&.kind.block?).try(&.restriction)
        return restriction if restriction.is_a?(Syntax::Proc)

        shim = @shims.find(entry)
        return unless shim

        shimmed = shim.parameters.find(&.kind.block?).try(&.restriction)
        shimmed.is_a?(Syntax::Proc) ? shimmed : nil
      end

      def unpacked_element(input : Resolution, position : Int32, name : String) : Resolution
        return input if input.is_a?(Unknown)
        unless input.is_a?(TypeRef)
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end
        if input.is?(:tuple)
          element = input.arguments[position]?
          return element || Unknown.new(:unsupported, "#{name} unpacks past the tuple's size")
        end

        chain = @types.ancestors(input.identity)
        inherits = !chain.is_a?(Unknown) && chain.includes?(CoreType::Indexable.identity)
        indexable = input.is?(:indexable) || inherits
        unless indexable
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end

        element = input.arguments[0]?
        element || Unknown.new(:unsupported, "#{name} unpacks #{input} with no element type")
      end

      def splatted(inputs : Array(Resolution), block : Crystal::Block) : Array(Resolution)
        return inputs unless inputs.size == 1 && block.args.size > 1

        elements = Array(Resolution).new(block.args.size)
        block.args.size.times do |index|
          element = tuple_element(inputs[0], index)
          return inputs unless element

          elements << element
        end
        elements
      end

      private def for_def(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        index : Int32,
        parameters : Int32,
      ) : Resolution
        proc_input = proc_block_input(entry, receiver, index)
        return proc_input if proc_input

        restriction = restriction_of(entry)
        if restriction.nil? || restriction.inputs.empty?
          return yielded(entry, index, receiver, arguments, parameters)
        end

        scope = @typer.scope_of(entry, receiver, arguments)
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
        @unions.union(elements)
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
        enclosing = owner.is_a?(Index::Identity) ? [owner] : Array(Index::Identity).new
        owner_vars = owner.is_a?(Index::Identity) ? @types.type_vars_of(owner) : Array(String).new
        type_vars = entry.free_vars + owner_vars
        sites = Syntax::YieldSites.in(
          definition, enclosing, type_vars, entry.path, @types.crystal_version
        )
        if sites.empty? && entry.macro_body
          return Unknown.new(:macro, "#{entry.qualified} yields only inside macro code")
        end
        if sites.empty?
          return Unknown.new(:no_annotation, "#{entry.qualified} never yields")
        end

        values = Array(Resolution).new(sites.size)
        visiting = Array(Visit){DefVisit.of(entry)}
        sites.each do |site|
          frame = Frame.new(site.context, Array(Binding).new, visiting)
          exps = site.node.exps
          if exps.size == 1 && parameters > 1
            packed = @typer.type_of(exps[0], frame)
            if packed.is_a?(TypeRef) && packed.is?(:tuple) && (element = packed.arguments[index]?)
              values << element
              next
            end
          end
          expression = exps[index]?
          unless expression
            return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values")
          end
          values << @typer.type_of(expression, frame)
        end
        scope = @typer.scope_of(entry, receiver, arguments)
        scope.is_a?(Unknown) ? @unions.union(values) : @unions.rebind(@unions.union(values), scope)
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
    end
  end
end
