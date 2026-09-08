require "../index/workspace"
require "./types"

module Heucristic
  module Resolve
    class Methods
      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
      end

      record Call, name : String, arity : Int32, block : Bool, arguments : Array(Resolution) do
        def self.new(name : String, arity : Int32, block : Bool) : Call
          new(name, arity, block, Array(Resolution).new)
        end

        def accepts?(entry : Index::Def) : Bool
          entry.arity.accepts?(arity) && entry.yields == block
        end
      end

      def compatible?(entry : Index::Def, call : Call) : Bool
        positional = entry.parameters.select(&.kind.positional?)
        owner = entry.owner
        owner_vars = owner.is_a?(String) ? @types.type_vars_of(owner) : Array(String).new
        type_vars = entry.free_vars + owner_vars
        scope = Scope.new(owner, type_vars)
        positional.zip?(call.arguments).all? do |parameter, argument|
          restriction = parameter.restriction
          next true if argument.nil? || argument.is_a?(Unknown) || !restriction.is_a?(Syntax::Type)

          admits?(@types.resolve_lexically(restriction, scope), argument)
        end
      end

      private def admits?(restriction : Resolution, argument : Resolved) : Bool
        case restriction
        in Unknown then true
        in UnionRef
          restriction.members.any? { |member| member.is_a?(Unknown) || admits?(member, argument) }
        in MetaRef then argument.is_a?(MetaRef)
        in TypeRef
          case argument
          in TypeRef
            argument.name == restriction.name || ancestor?(argument.name, restriction.name)
          in UnionRef
            argument.members.all? { |member| member.is_a?(Unknown) || admits?(restriction, member) }
          in MetaRef then restriction.name == "Class"
          end
        end
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

      private def instance_methods(type : String, call : Call) : Array(Index::Def)
        first_level(type, call.name) do |entry|
          entry.receiver.instance? && call.accepts?(entry) && compatible?(entry, call)
        end
      end

      private def class_methods(type : String, call : Call) : Array(Index::Def)
        found = first_level(type, call.name) do |entry|
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
        name : String,
        & : Index::Def -> Bool
      ) : Array(Index::Def)
        candidates = @workspace.named(name)
        levels(type).each do |level|
          found = candidates.select { |entry| entry.owner == level && yield entry }
          return found unless found.empty?
        end
        Array(Index::Def).new
      end

      private def levels(type : String) : Array(String)
        chain = @types.ancestors(type)
        chain.is_a?(Unknown) ? [type] : [type] + chain
      end
    end
  end
end
