require "../index/workspace"
require "./types"

module Heucristic
  module Resolve
    class Methods
      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
      end

      def lookup(receiver : Resolution, name : String, arity : Int32) : Array(Index::Def)
        case receiver
        in TypeRef  then instance_methods(receiver.name, name, arity)
        in MetaRef  then class_methods(receiver.of.name, name, arity)
        in UnionRef then receiver.members.flat_map { |member| lookup(member, name, arity) }.uniq!
        in Unknown  then Array(Index::Def).new
        end
      end

      private def instance_methods(type : String, name : String, arity : Int32) : Array(Index::Def)
        first_level(type, name) { |entry| entry.receiver.instance? && entry.arity.accepts?(arity) }
      end

      private def class_methods(type : String, name : String, arity : Int32) : Array(Index::Def)
        found = first_level(type, name) do |entry|
          entry.receiver.metaclass? && entry.arity.accepts?(arity)
        end
        return found unless found.empty?

        extended = extended_methods(type, name, arity)
        return extended unless extended.empty?
        return extended unless name == "new"

        instance_methods(type, "initialize", arity)
      end

      private def extended_methods(type : String, name : String, arity : Int32) : Array(Index::Def)
        levels(type).each do |level|
          @workspace.mixins_of(level).reverse_each do |mixin|
            next unless mixin.kind.extend?

            module_name = extended_module(mixin, level)
            next unless module_name

            found = instance_methods(module_name, name, arity)
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
