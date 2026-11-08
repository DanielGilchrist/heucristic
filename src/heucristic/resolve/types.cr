require "../index/workspace"
require "../index/restriction"
require "./resolution"
require "./scope"
require "./builtins"
require "./ancestors"
require "./compiled"

module Heucristic
  module Resolve
    class Types
      record LocateKey,
        names : Array(String),
        global : Bool,
        namespace : Index::Owner,
        type_vars : Array(String),
        path : String?,
        ancestors : Bool,
        constants : Bool

      def initialize(@workspace : Index::Workspace) : Nil
        @following = Array(String).new
        @descending = Array(String).new
        @ancestors = Ancestors.new(@workspace)
        @inheriting = Array(String).new
        @located = Hash(LocateKey, String | Unknown).new
        @compiled = Compiled::NONE
      end

      def invalidate : Nil
        @ancestors.invalidate
        @located.clear
      end

      def compiled(map : Compiled) : Nil
        @compiled = map
        invalidate
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

      def splat_index_of(name : String) : Int32?
        @ancestors.splat_index_of(name)
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

      private NIL = Syntax::Named.of(:nil)

      private def resolve(type : Syntax::Type, scope : Scope, with_ancestors : Bool) : Resolution
        case type
        in Syntax::Named      then resolve_named(type, scope, Array(String).new, with_ancestors)
        in Syntax::Generic    then resolve_generic(type, scope, with_ancestors)
        in Syntax::Union      then resolve_union(type.members, scope, with_ancestors)
        in Syntax::Nilable    then resolve_nilable(type, scope, with_ancestors)
        in Syntax::Metaclass  then resolve_metaclass(type, scope, with_ancestors)
        in Syntax::SelfType   then resolve_self(scope)
        in Syntax::Proc       then resolve_proc(type, scope, with_ancestors)
        in Syntax::Splat      then resolve_splat(type, scope)
        in Syntax::TypeOf     then scope.bound(type.to_s) || Unknown.new(:unsupported, type.to_s)
        in Syntax::Underscore then Unknown.new(:unsupported, type.to_s)
        in Syntax::Literal    then Unknown.new(:non_type_argument, type.source)
        end
      end

      private def locate(
        path : Syntax::Named,
        scope : Scope,
        with_ancestors : Bool,
        constants : Bool,
      ) : String | Unknown
        key = LocateKey.new(
          path.names, path.global?, scope.namespace, scope.type_vars, scope.path,
          with_ancestors, constants,
        )
        cached = @located[key]?
        return cached unless cached.nil?

        @located[key] = search(path, scope, with_ancestors, constants)
      end

      private def search(
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
        scopes.concat(top_level_includes(scope)) unless path.global?
        scopes.each do |prefix|
          search_in(prefix, with_ancestors) do |namespace|
            head = qualify(namespace, first)
            next unless declared?(head, constants, scope)

            return head if rest.empty?

            return descend(through_alias(head, scope), rest, constants, scope)
          end
        end

        Unknown.new(:unresolved_name, path.to_s)
      end

      private def descend(
        head : String,
        rest : Array(String),
        constants : Bool,
        scope : Scope,
      ) : String | Unknown
        current = head
        rest.each_with_index do |segment, position|
          found = child_of(current, segment, constants, scope)
          return Unknown.new(:unresolved_name, "#{current}::#{segment}") unless found

          current = position == rest.size - 1 ? found : through_alias(found, scope)
        end
        current
      end

      private def child_of(
        parent : String,
        segment : String,
        constants : Bool,
        scope : Scope,
      ) : String?
        direct = "#{parent}::#{segment}"
        return direct if declared?(direct, constants, scope)
        return direct if enum_member?(parent, direct, scope)
        return if @descending.includes?(parent)

        @descending << parent
        begin
          chain = @ancestors.of(parent, self)
          return if chain.is_a?(Unknown)

          chain.each do |ancestor|
            inherited = "#{ancestor}::#{segment}"
            return inherited if declared?(inherited, constants, scope)
          end
          nil
        ensure
          @descending.pop
        end
      end

      private def enum_member?(parent : String, full : String, scope : Scope) : Bool
        return false unless @workspace.enum?(parent)

        @workspace.constants(full).any? { |entry| visible?(entry.private_path, scope) }
      end

      private def top_level_includes(scope : Scope) : Array(Index::Owner)
        included = Array(Index::Owner).new
        @workspace.mixins_of(Index::TopLevel.new).each do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Named)

          full = target.names.join("::")
          included << full if declared?(full, false, scope)
        end
        included
      end

      private def through_alias(name : String, scope : Scope) : String
        aliases = visible_aliases(name, scope)
        return name if aliases.empty?

        targets = loaded(aliases).map(&.target).uniq!
        return name unless targets.size == 1

        target = targets[0]
        return name unless target.is_a?(Syntax::Named)

        owner = name.rpartition("::")[0]
        owner_scope = Scope.new(owner, Array(String).new, Array(Binding).new, scope.path)
        resolved = resolve_named(target, owner_scope, [name], false)
        resolved.is_a?(TypeRef) ? resolved.name : name
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
        if type.names.size == 1 && !type.global?
          name = type.names[0]
          bound = scope.bound(name)
          return bound if bound
          return TypeVar.new(name) if scope.type_vars.includes?(name)
        end

        located = locate(type, scope, with_ancestors, false)
        if located.is_a?(Unknown)
          inherited = inherited_type_var(type, scope) if located.reason.unresolved_name?
          return inherited || located
        end

        follow(located, visiting, with_ancestors, scope)
      end

      private def inherited_type_var(type : Syntax::Named, scope : Scope) : Resolution?
        return if type.names.size != 1 || type.global?

        owner = scope.namespace
        return unless owner.is_a?(String)
        return if @inheriting.includes?(owner)

        @inheriting << owner
        begin
          inherited_type_var(type.names[0], owner, scope)
        ensure
          @inheriting.pop
        end
      end

      private def inherited_type_var(name : String, owner : String, scope : Scope) : Resolution?
        chain = ancestors(owner)
        return if chain.is_a?(Unknown)

        parent = chain.find { |ancestor| type_vars_of(ancestor).includes?(name) }
        return unless parent

        own = Array(Resolution).new
        type_vars_of(owner).each do |type_var|
          own << (scope.bound(type_var) || TypeVar.new(type_var))
        end
        bindings = bindings(TypeRef.new(owner, own), parent)
        return if bindings.is_a?(Unknown)

        bindings.find(&.name.==(name)).try(&.value)
      end

      private def follow(
        full : String,
        visiting : Array(String),
        with_ancestors : Bool,
        scope : Scope,
      ) : Resolution
        aliases = visible_aliases(full, scope)
        return TypeRef.new(full, Array(Resolution).new) if aliases.empty?
        if visiting.includes?(full) || @following.includes?(full)
          return TypeRef.new(full, Array(Resolution).new)
        end

        candidates = loaded(aliases)
        targets = candidates.map(&.target).uniq!
        if targets.size > 1
          places = candidates.map(&.path).sort!.join(", ")
          return Unknown.new(:ambiguous, "#{full} is declared differently in #{places}")
        end

        target = targets[0]
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        scope = Scope.of(full.rpartition("::")[0])
        @following << full
        begin
          if target.is_a?(Syntax::Named)
            resolve_named(target, scope, visiting + [full], with_ancestors)
          else
            resolve(target, scope, with_ancestors)
          end
        ensure
          @following.pop
        end
      end

      private def loaded(aliases : Array(Index::Alias)) : Array(Index::Alias)
        known = aliases.select { |entry| @compiled.known?(entry.path) }
        known.empty? ? aliases : known
      end

      private def declared?(name : String, constants : Bool, scope : Scope) : Bool
        namespaces = @workspace.namespaces(name)
        return true if namespaces.any? { |entry| visible?(entry.private_path, scope) }
        return true unless visible_aliases(name, scope).empty?
        return true if @workspace.encloses?(name)
        if constants
          return true if Builtins.constant?(name)
          constants_named = @workspace.constants(name)
          return true if constants_named.any? { |entry| visible?(entry.private_path, scope) }
        end

        !name.includes?("::") && Builtins.includes?(name)
      end

      private def visible_aliases(name : String, scope : Scope) : Array(Index::Alias)
        @workspace.aliases(name).select { |entry| visible?(entry.private_path, scope) }
      end

      private def visible?(private_path : String?, scope : Scope) : Bool
        private_path.nil? || private_path == scope.path
      end

      private def resolve_generic(
        type : Syntax::Generic,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        base = resolve_named(type.base, scope, Array(String).new, with_ancestors)
        return base unless base.is_a?(TypeRef)
        unless type.named_arguments.empty?
          unless type.arguments.empty? && base.is?(:named_tuple)
            return Unknown.new(:unsupported, "named type arguments in #{type}")
          end

          labelled = Array(Resolution).new(type.named_arguments.size)
          type.named_arguments.each do |argument|
            labelled << resolve(argument.type, scope, with_ancestors)
          end
          return TypeRef.new(base.name, labelled, type.named_arguments.map(&.name))
        end

        arguments = Array(Resolution).new(type.arguments.size)
        type.arguments.each do |argument|
          pack = argument.is_a?(Syntax::Splat) ? splat_pack(argument, scope) : nil
          if pack
            arguments.concat(pack.arguments)
          else
            arguments << resolve(argument, scope, with_ancestors)
          end
        end
        return union_of(arguments) if base.name == CoreType::Union.type_name

        TypeRef.new(base.name, arguments)
      end

      private def resolve_proc(
        type : Syntax::Proc,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        arguments = Array(Resolution).new(type.inputs.size + 1)
        type.inputs.each { |input| arguments << resolve(input, scope, with_ancestors) }
        output = type.output
        arguments << if output
          resolve(output, scope, with_ancestors)
        else
          TypeRef.of(:nil)
        end
        TypeRef.of(:proc, arguments)
      end

      private def resolve_splat(type : Syntax::Splat, scope : Scope) : Resolution
        inner = type.inner
        return Unknown.new(:unsupported, type.to_s) unless inner.is_a?(Syntax::Named)
        if inner.names.size == 1 && (bound = scope.bound(inner.names[0]))
          return bound
        end

        Unknown.new(:unsupported, type.to_s)
      end

      private def splat_pack(type : Syntax::Splat, scope : Scope) : TypeRef?
        inner = type.inner
        return unless inner.is_a?(Syntax::Named) && inner.names.size == 1

        bound = scope.bound(inner.names[0])
        bound.is_a?(TypeRef) && bound.is?(:tuple) ? bound : nil
      end

      private def union_of(members : Array(Resolution)) : Resolution
        flat = Array(Resolution).new
        members.each do |member|
          return member if member.is_a?(Unknown)
          next if member.is_a?(TypeRef) && member.is?(:no_return)
          if member.is_a?(UnionRef)
            member.members.each { |inner| flat << inner unless flat.includes?(inner) }
          else
            flat << member unless flat.includes?(member)
          end
        end
        UnionRef.join(flat)
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
          next if resolution.is_a?(TypeRef) && resolution.is?(:no_return)
          if resolution.is_a?(UnionRef)
            resolution.members.each { |inner| resolved << inner unless resolved.includes?(inner) }
          else
            resolved << resolution unless resolved.includes?(resolution)
          end
        end
        UnionRef.join(resolved)
      end

      private def resolve_metaclass(
        type : Syntax::Metaclass,
        scope : Scope,
        with_ancestors : Bool,
      ) : Resolution
        inner = resolve(type.of, scope, with_ancestors)
        return inner if inner.is_a?(Unknown)
        return MetaRef.new(inner) if inner.is_a?(TypeRef) || inner.is_a?(TypeVar)

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
