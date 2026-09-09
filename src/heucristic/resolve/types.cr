require "../index/workspace"
require "../index/restriction"
require "./resolution"
require "./scope"
require "./builtins"
require "./ancestors"

module Heucristic
  module Resolve
    class Types
      def initialize(@workspace : Index::Workspace) : Nil
        @ancestors = Ancestors.new(@workspace)
      end

      def invalidate : Nil
        @ancestors.invalidate
      end

      def ancestors(name : String) : Ancestors::Chain
        @ancestors.of(name, self)
      end

      def bindings(receiver : TypeRef, owner : String) : Array(Binding) | Unknown
        @ancestors.bindings(receiver, owner, self)
      end

      def type_vars_of(name : String) : Array(String)
        @ancestors.type_vars_of(name)
      end

      def resolve(restriction : Index::Restriction, scope : Scope) : Resolution
        case restriction
        in Index::Unrestricted             then Unknown.new(:no_annotation, "no type restriction")
        in Syntax::TypeReader::Unsupported then Unknown.new(:unsupported, restriction.source)
        in Syntax::Type                    then resolve(restriction, scope)
        end
      end

      def resolve(type : Syntax::Type, scope : Scope) : Resolution
        resolve(type, scope, true)
      end

      def resolve_lexically(type : Syntax::Type, scope : Scope) : Resolution
        resolve(type, scope, false)
      end

      def locate(path : Syntax::Named, scope : Scope) : String | Unknown
        locate(path, scope, true, false)
      end

      def locate_any(path : Syntax::Named, scope : Scope) : String | Unknown
        locate(path, scope, true, true)
      end

      private NIL = Syntax::Named.new(["Nil"], true)

      private def resolve(type : Syntax::Type, scope : Scope, with_ancestors : Bool) : Resolution
        case type
        in Syntax::Named     then resolve_named(type, scope, Array(String).new, with_ancestors)
        in Syntax::Generic   then resolve_generic(type, scope, with_ancestors)
        in Syntax::Union     then resolve_union(type.members, scope, with_ancestors)
        in Syntax::Nilable   then resolve_nilable(type, scope, with_ancestors)
        in Syntax::Metaclass then resolve_metaclass(type, scope, with_ancestors)
        in Syntax::SelfType  then resolve_self(scope)
        in Syntax::Proc      then Unknown.new(:unsupported, "proc types are not resolved yet")
        in Syntax::TypeOf, Syntax::Splat, Syntax::Underscore
          Unknown.new(:unsupported, type.to_s)
        in Syntax::Literal then Unknown.new(:non_type_argument, type.source)
        end
      end

      private def locate(
        path : Syntax::Named,
        scope : Scope,
        with_ancestors : Bool,
        constants : Bool,
      ) : String | Unknown
        first = path.names[0]
        rest = path.names[1..]
        if path.names.size == 1 && !path.global? && scope.type_vars.includes?(first)
          return Unknown.new(:free_variable, first)
        end

        scopes = path.global? ? [Index::TopLevel.new] of Index::Owner : scope.chain
        scopes.each do |prefix|
          search_in(prefix, with_ancestors) do |namespace|
            head = qualify(namespace, first)
            next unless declared?(head, constants)

            full = rest.empty? ? head : "#{head}::#{rest.join("::")}"
            return declared?(full, constants) ? full : Unknown.new(:unresolved_name, full)
          end
        end

        Unknown.new(:unresolved_name, path.to_s)
      end

      private def search_in(
        namespace : Index::Owner,
        with_ancestors : Bool,
        & : Index::Owner ->
      ) : Nil
        yield namespace
        return unless namespace.is_a?(String) && with_ancestors

        chain = @ancestors.of(namespace, self)
        return if chain.is_a?(Unknown)

        chain.each { |ancestor| yield ancestor }
      end

      private def qualify(namespace : Index::Owner, name : String) : String
        case namespace
        in Index::TopLevel then name
        in String          then "#{namespace}::#{name}"
        end
      end

      private def resolve_named(
        type : Syntax::Named,
        scope : Scope,
        visiting : Array(String),
        with_ancestors : Bool,
      ) : Resolution
        if type.names.size == 1 && !type.global? && (bound = scope.bound(type.names[0]))
          return bound
        end

        located = locate(type, scope, with_ancestors, false)
        return located if located.is_a?(Unknown)

        follow(located, visiting, with_ancestors)
      end

      private def follow(
        full : String,
        visiting : Array(String),
        with_ancestors : Bool,
      ) : Resolution
        aliases = @workspace.aliases(full)
        return TypeRef.new(full, Array(Resolution).new) if aliases.empty?
        return Unknown.new(:cycle, full) if visiting.includes?(full)

        target = aliases[0].target
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        scope = Scope.of(full.rpartition("::")[0])
        if target.is_a?(Syntax::Named)
          return resolve_named(target, scope, visiting + [full], with_ancestors)
        end

        resolve(target, scope, with_ancestors)
      end

      private def declared?(name : String, constants : Bool) : Bool
        return true if !@workspace.namespaces(name).empty? || !@workspace.aliases(name).empty?
        return true if constants && !@workspace.constants(name).empty?

        !name.includes?("::") && Builtins.includes?(name)
      end

      private def resolve_generic(
        type : Syntax::Generic,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        unless type.named_arguments.empty?
          return Unknown.new(:unsupported, "named type arguments in #{type}")
        end

        base = resolve_named(type.base, scope, Array(String).new, with_ancestors)
        return base unless base.is_a?(TypeRef)

        arguments = type.arguments.map { |argument| resolve(argument, scope, with_ancestors) }
        TypeRef.new(base.name, arguments)
      end

      private def resolve_nilable(
        type : Syntax::Nilable,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        resolve_union([type.inner, NIL] of Syntax::Type, scope, with_ancestors)
      end

      private def resolve_union(
        members : Array(Syntax::Type),
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        resolved = Array(Resolution).new(members.size)
        members.each do |member|
          resolution = resolve(member, scope, with_ancestors)
          return resolution if resolution.is_a?(Unknown)
          next if resolution.is_a?(TypeRef) && resolution.name == "NoReturn"
          if resolution.is_a?(UnionRef)
            resolution.members.each { |inner| resolved << inner unless resolved.includes?(inner) }
          else
            resolved << resolution unless resolved.includes?(resolution)
          end
        end
        return TypeRef.new("NoReturn", Array(Resolution).new) if resolved.empty?

        resolved.size == 1 ? resolved[0] : UnionRef.new(resolved)
      end

      private def resolve_metaclass(
        type : Syntax::Metaclass,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        inner = resolve(type.of, scope, with_ancestors)
        return inner if inner.is_a?(Unknown)
        return MetaRef.new(inner) if inner.is_a?(TypeRef)

        Unknown.new(:unsupported, "metaclass of #{inner}")
      end

      private def resolve_self(scope : Scope) : Resolution
        if (bound = scope.bound("self"))
          return bound
        end

        case (namespace = scope.namespace)
        in Index::TopLevel then Unknown.new(:unsupported, "self outside a type")
        in String
          arguments = type_vars_of(namespace).compact_map { |type_var| scope.bound(type_var) }
          TypeRef.new(namespace, arguments)
        end
      end
    end
  end
end
