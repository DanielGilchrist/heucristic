require "../index/workspace"
require "./types"

module Heucristic
  module Resolve
    class Methods
      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
      end

      record Call,
        name : String,
        arity : Int32,
        block : Bool,
        arguments : Array(Resolution),
        named : Array(String),
        named_arguments : Array(Binding) = Array(Binding).new do
        def self.new(name : String, arity : Int32, block : Bool) : Call
          new(name, arity, block, Array(Resolution).new, Array(String).new)
        end

        def self.new(
          name : String,
          arity : Int32,
          block : Bool,
          arguments : Array(Resolution),
        ) : Call
          new(name, arity, block, arguments, Array(String).new)
        end

        def accepts?(entry : Index::Def) : Bool
          entry.arity.accepts?(arity) && entry.yields == block && keywords_satisfied?(entry)
        end

        private def keywords_satisfied?(entry : Index::Def) : Bool
          required = entry.parameters.all? do |parameter|
            next true unless parameter.kind.keyword?

            parameter.default || named.includes?(parameter.external_name)
          end
          return false unless required
          return true if entry.parameters.any?(&.kind.double_splat?)

          named.all? do |name|
            entry.parameters.any? do |parameter|
              next false unless parameter.kind.keyword? || parameter.kind.positional?

              parameter.external_name == name
            end
          end
        end
      end

      def compatible?(entry : Index::Def, call : Call) : Bool
        positional = entry.parameters.select(&.kind.positional?)
        owner = entry.owner
        owner_vars = owner.is_a?(String) ? @types.type_vars_of(owner) : Array(String).new
        type_vars = entry.free_vars + owner_vars
        scope = Scope.new(owner, type_vars)
        splat = entry.parameters.find(&.kind.splat?)
        call.arguments.each_with_index.all? do |argument, index|
          parameter = positional[index]? || splat
          restriction = parameter.try(&.restriction)
          next true if argument.is_a?(Unknown) || !restriction.is_a?(Syntax::Type)

          admits?(@types.resolve_lexically(restriction, scope), argument)
        end
      end

      private def admits?(restriction : Resolution, argument : Resolved) : Bool
        if argument.is_a?(UnionRef)
          return argument.members.all? do |member|
            member.is_a?(Unknown) || admits?(restriction, member)
          end
        end

        case restriction
        in Unknown then true
        in UnionRef
          restriction.members.any? { |member| member.is_a?(Unknown) || admits?(member, argument) }
        in MetaRef then argument.is_a?(MetaRef)
        in TypeRef
          case argument
          in TypeRef
            argument.name == restriction.name ||
              ancestor?(argument.name, restriction.name) ||
              autocast?(argument, restriction)
          in UnionRef then false
          in MetaRef  then restriction.name == "Class"
          end
        end
      end

      private def autocast?(argument : TypeRef, restriction : TypeRef) : Bool
        return false unless argument.name == "Symbol"

        @workspace.namespaces(restriction.name).any?(Index::EnumNamespace)
      end

      private def ancestor?(type : String, candidate : String) : Bool
        chain = @types.ancestors(type)
        chain.is_a?(Unknown) || chain.includes?(candidate)
      end

      def lookup(receiver : Resolution, call : Call) : Array(Index::Def)
        case receiver
        in TypeRef  then instance_methods(receiver.name, call)
        in MetaRef  then class_methods(receiver.of.name, call)
        in UnionRef then receiver.members.flat_map { |member| lookup(member, call) }.uniq!
        in Unknown  then Array(Index::Def).new
        end
      end

      def lookup_super(receiver : Resolved, owner : String, call : Call) : Array(Index::Def)
        case receiver
        in TypeRef
          first_level(receiver.name, call, after: owner) do |entry|
            entry.receiver.instance? && call.accepts?(entry) && compatible?(entry, call)
          end
        in MetaRef
          first_level(receiver.of.name, call, after: owner) do |entry|
            entry.receiver.metaclass? && call.accepts?(entry) && compatible?(entry, call)
          end
        in UnionRef then Array(Index::Def).new
        end
      end

      private def instance_methods(type : String, call : Call) : Array(Index::Def)
        first_level(type, call) do |entry|
          entry.receiver.instance? && call.accepts?(entry) && compatible?(entry, call)
        end
      end

      private def class_methods(type : String, call : Call) : Array(Index::Def)
        found = first_level(type, call) do |entry|
          entry.receiver.metaclass? && call.accepts?(entry) && compatible?(entry, call)
        end
        return found unless found.empty?

        extended = extended_methods(type, call)
        return extended unless extended.empty?
        return extended unless call.name == "new"

        instance_methods(type, Call.new("initialize", call.arity, call.block))
      end

      private def extended_methods(type : String, call : Call) : Array(Index::Def)
        levels(type).each do |level|
          @workspace.mixins_of(level).reverse_each do |mixin|
            next unless mixin.kind.extend?

            module_name = extended_module(mixin, level)
            next unless module_name

            found = instance_methods(module_name, call)
            return found unless found.empty?
          end
        end
        Array(Index::Def).new
      end

      private def extended_module(mixin : Index::Mixin, owner : String) : String?
        target = mixin.target
        return if target.is_a?(Syntax::TypeReader::Unsupported)

        scope = Scope.new(owner, @types.type_vars_of(owner))
        resolved = @types.resolve_lexically(target, scope)
        resolved.is_a?(TypeRef) ? resolved.name : nil
      end

      private def first_level(
        type : String,
        call : Call,
        after : String? = nil,
        & : Index::Def -> Bool
      ) : Array(Index::Def)
        candidates = @workspace.named(call.name)
        searched = levels(type)
        if after && (start = searched.index(after))
          searched = searched[(start + 1)..]
        end
        searched.each do |level|
          found = candidates.select { |entry| entry.owner == level && yield entry }
          return most_specific(found, call) unless found.empty?
        end
        Array(Index::Def).new
      end

      private def most_specific(found : Array(Index::Def), call : Call) : Array(Index::Def)
        found.reject do |entry|
          found.any? { |other| other != entry && stricter?(other, entry, call) }
        end
      end

      private def stricter?(candidate : Index::Def, other : Index::Def, call : Call) : Bool
        left = candidate.parameters.select(&.kind.positional?)
        right = other.parameters.select(&.kind.positional?)
        return false unless left.size == right.size

        strictly = false
        left.each_with_index do |mine, index|
          theirs = right[index]
          known = call.arguments[index]?.try { |argument| !argument.is_a?(Unknown) } || false
          mine_restricted = !mine.restriction.is_a?(Index::Unrestricted)
          theirs_restricted = !theirs.restriction.is_a?(Index::Unrestricted)
          return false if mine_restricted != theirs_restricted && !known
          return false if theirs_restricted && !mine_restricted
          if mine_restricted && theirs_restricted
            return false unless mine.restriction == theirs.restriction
          end
          strictly ||= mine_restricted && !theirs_restricted
        end
        strictly
      end

      private def levels(type : String) : Array(String)
        chain = @types.ancestors(type)
        chain.is_a?(Unknown) ? [type] : [type] + chain
      end
    end
  end
end
