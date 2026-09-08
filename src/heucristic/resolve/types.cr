require "../index/workspace"
require "../index/restriction"
require "./resolution"
require "./scope"
require "./builtins"

module Heucristic
  module Resolve
    class Types
      def initialize(@workspace : Index::Workspace) : Nil
      end

      def resolve(restriction : Index::Restriction, scope : Scope) : Resolution
        case restriction
        in Index::Unrestricted             then Unknown.new(:no_annotation, "no type restriction")
        in Syntax::TypeReader::Unsupported then Unknown.new(:unsupported, restriction.source)
        in Syntax::Type                    then resolve(restriction, scope)
        end
      end

      def resolve(type : Syntax::Type, scope : Scope) : Resolution
        case type
        in Syntax::Named     then resolve_named(type, scope, Array(String).new)
        in Syntax::Generic   then resolve_generic(type, scope)
        in Syntax::Union     then resolve_union(type.members, scope)
        in Syntax::Nilable   then resolve_union([type.inner, NIL] of Syntax::Type, scope)
        in Syntax::Metaclass then resolve_metaclass(type, scope)
        in Syntax::SelfType  then resolve_self(scope)
        in Syntax::Proc      then Unknown.new(:unsupported, "proc types are not resolved yet")
        in Syntax::TypeOf, Syntax::Splat, Syntax::Underscore
          Unknown.new(:unsupported, type.to_s)
        in Syntax::Literal then Unknown.new(:non_type_argument, type.source)
        end
      end

      def locate(path : Syntax::Named, scope : Scope) : String | Unknown
        first = path.names[0]
        rest = path.names[1..]
        if path.names.size == 1 && !path.global? && scope.type_vars.includes?(first)
          return Unknown.new(:free_variable, first)
        end

        scopes = path.global? ? [""] : scope.chain
        scopes.each do |prefix|
          head = prefix.empty? ? first : "#{prefix}::#{first}"
          next unless declared?(head)

          full = rest.empty? ? head : "#{head}::#{rest.join("::")}"
          return declared?(full) ? full : Unknown.new(:unresolved_name, full)
        end

        Unknown.new(:unresolved_name, path.to_s)
      end

      private NIL = Syntax::Named.new(["Nil"], true)

      private def resolve_named(
        type : Syntax::Named,
        scope : Scope,
        visiting : Array(String),
      ) : Resolution
        located = locate(type, scope)
        return located if located.is_a?(Unknown)

        follow(located, visiting)
      end

      private def follow(full : String, visiting : Array(String)) : Resolution
        aliases = @workspace.aliases(full)
        return TypeRef.new(full, Array(Resolution).new) if aliases.empty?
        return Unknown.new(:alias_cycle, full) if visiting.includes?(full)

        target = aliases[0].target
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        owner = full.rpartition("::")[0]
        resolve_following(target, Scope.of(owner), visiting + [full])
      end

      private def resolve_following(
        target : Syntax::Type,
        scope : Scope,
        visiting : Array(String),
      ) : Resolution
        return resolve_named(target, scope, visiting) if target.is_a?(Syntax::Named)

        resolve(target, scope)
      end

      private def declared?(name : String) : Bool
        return true if !@workspace.namespaces(name).empty? || !@workspace.aliases(name).empty?

        !name.includes?("::") && Builtins.includes?(name)
      end

      private def resolve_generic(type : Syntax::Generic, scope : Scope) : Resolution
        unless type.named_arguments.empty?
          return Unknown.new(:unsupported, "named type arguments in #{type}")
        end

        base = resolve_named(type.base, scope, Array(String).new)
        return base unless base.is_a?(TypeRef)

        arguments = type.arguments.map { |argument| resolve(argument, scope) }
        TypeRef.new(base.name, arguments)
      end

      private def resolve_union(members : Array(Syntax::Type), scope : Scope) : Resolution
        resolved = Array(Resolution).new(members.size)
        members.each do |member|
          resolution = resolve(member, scope)
          return resolution if resolution.is_a?(Unknown)
          resolved << resolution
        end
        UnionRef.new(resolved)
      end

      private def resolve_metaclass(type : Syntax::Metaclass, scope : Scope) : Resolution
        inner = resolve(type.of, scope)
        return inner if inner.is_a?(Unknown)
        return MetaRef.new(inner) if inner.is_a?(TypeRef)

        Unknown.new(:unsupported, "metaclass of #{inner}")
      end

      private def resolve_self(scope : Scope) : Resolution
        return Unknown.new(:unsupported, "self outside a type") if scope.namespace.empty?

        TypeRef.new(scope.namespace, Array(Resolution).new)
      end
    end
  end
end
