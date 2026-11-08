require "../index/workspace"
require "../index/restriction"
require "./resolution"
require "./scope"
require "./builtins"
require "./ancestors"
require "./compiled"
require "./lookup"

module Heucristic
  module Resolve
    class Types
      record LocateKey,
        names : Array(String),
        global : Bool,
        namespace : Index::Owner,
        type_vars : Array(String),
        path : String?,
        lookup : Lookup

      def initialize(@workspace : Index::Workspace) : Nil
        @following = Array(Index::Identity).new
        @descending = Array(Index::Identity).new
        @ancestors = Ancestors.new(@workspace)
        @inheriting = Array(Index::Identity).new
        @located = Hash(LocateKey, Index::Identity | Unknown).new
        @compiled = Compiled::NONE
      end

      def crystal_version : CrystalVersion::Detected
        @workspace.crystal_version
      end

      def invalidate : Nil
        @ancestors.invalidate
        @located.clear
      end

      def compiled(map : Compiled) : Nil
        @compiled = map
        invalidate
      end

      def ancestors(identity : Index::Identity) : Ancestors::Chain
        @ancestors.of(identity, self)
      end

      def bindings(receiver : TypeRef, owner : Index::Identity) : Array(Binding) | Unknown
        @ancestors.bindings(receiver, owner, self)
      end

      def type_vars_of(identity : Index::Identity) : Array(String)
        @ancestors.type_vars_of(identity)
      end

      def splat_index_of(identity : Index::Identity) : Int32?
        @ancestors.splat_index_of(identity)
      end

      def resolve(restriction : Index::Restriction, scope : Scope) : Resolution
        case restriction
        in Index::Unrestricted             then Unknown.new(:no_annotation, "no type restriction")
        in Syntax::TypeReader::Unsupported then Unknown.new(:unsupported, restriction.source)
        in Syntax::Type                    then resolve(restriction, scope)
        end
      end

      def resolve(type : Syntax::Type, scope : Scope) : Resolution
        resolve(type, scope, :inherited)
      end

      def resolve_lexically(type : Syntax::Type, scope : Scope) : Resolution
        resolve(type, scope, :lexical)
      end

      def locate(path : Syntax::Named, scope : Scope) : Index::Identity | Unknown
        locate(path, scope, :inherited)
      end

      def locate_any(path : Syntax::Named, scope : Scope) : Index::Identity | Unknown
        locate(path, scope, :any)
      end

      private NIL = Syntax::Named.of(:nil)

      private def resolve(type : Syntax::Type, scope : Scope, lookup : Lookup) : Resolution
        case type
        in Syntax::Named      then resolve_named(type, scope, Array(Index::Identity).new, lookup)
        in Syntax::Generic    then resolve_generic(type, scope, lookup)
        in Syntax::Union      then resolve_union(type.members, scope, lookup)
        in Syntax::Nilable    then resolve_nilable(type, scope, lookup)
        in Syntax::Metaclass  then resolve_metaclass(type, scope, lookup)
        in Syntax::SelfType   then resolve_self(scope)
        in Syntax::Proc       then resolve_proc(type, scope, lookup)
        in Syntax::Splat      then resolve_splat(type, scope)
        in Syntax::TypeOf     then scope.bound(type.to_s) || Unknown.new(:unsupported, type.to_s)
        in Syntax::Underscore then Unknown.new(:unsupported, type.to_s)
        in Syntax::Literal    then Unknown.new(:non_type_argument, type.source)
        end
      end

      private def locate(
        path : Syntax::Named,
        scope : Scope,
        lookup : Lookup,
      ) : Index::Identity | Unknown
        key = LocateKey.new(
          path.names, path.global?, scope.namespace, scope.type_vars, scope.path,
          lookup,
        )
        cached = @located[key]?
        return cached unless cached.nil?

        @located[key] = search(path, scope, lookup)
      end

      private def search(
        path : Syntax::Named,
        scope : Scope,
        lookup : Lookup,
      ) : Index::Identity | Unknown
        first = path.names[0]
        rest = path.names[1..]
        if path.names.size == 1 && !path.global? && scope.type_vars.includes?(first)
          return Unknown.new(:free_variable, first)
        end

        scopes = path.global? ? [Index::TopLevel.new] of Index::Owner : scope.chain
        scopes.concat(top_level_includes(scope)) unless path.global?
        scopes.each do |prefix|
          search_in(prefix, lookup) do |namespace|
            each_head(namespace, first, scope.path) do |head|
              next unless declared?(head, lookup)

              return head if rest.empty?

              return descend(through_alias(head, scope), rest, lookup, scope)
            end
          end
        end

        Unknown.new(:unresolved_name, path.to_s)
      end

      private def descend(
        head : Index::Identity,
        rest : Array(String),
        lookup : Lookup,
        scope : Scope,
      ) : Index::Identity | Unknown
        current = head
        rest.each_with_index do |segment, position|
          found = child_of(current, segment, lookup)
          return Unknown.new(:unresolved_name, "#{current}::#{segment}") unless found

          current = position == rest.size - 1 ? found : through_alias(found, scope)
        end
        current
      end

      private def child_of(
        parent : Index::Identity,
        segment : String,
        lookup : Lookup,
      ) : Index::Identity?
        direct = parent.child(segment)
        return direct if declared?(direct, lookup)
        return direct if enum_member?(parent, direct)
        return if @descending.includes?(parent)

        @descending << parent
        begin
          chain = @ancestors.of(parent, self)
          return if chain.is_a?(Unknown)

          chain.each do |ancestor|
            inherited = ancestor.child(segment)
            return inherited if declared?(inherited, lookup)
          end
          nil
        ensure
          @descending.pop
        end
      end

      private def enum_member?(parent : Index::Identity, full : Index::Identity) : Bool
        @workspace.enum?(parent) && !@workspace.constants(full).empty?
      end

      private def top_level_includes(scope : Scope) : Array(Index::Owner)
        included = Array(Index::Owner).new
        @workspace.mixins_of(Index::TopLevel.new).each do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Named)

          included_type(target, mixin.path).try { |type| included << type }
        end
        included
      end

      private def included_type(target : Syntax::Named, path : String) : Index::Identity?
        current = declared_head(target.names[0], path)
        target.names[1..].each do |segment|
          parent = current
          return unless parent

          child = parent.child(segment)
          current = declared?(child, :lexical) ? child : nil
        end
        current
      end

      private def declared_head(name : String, path : String) : Index::Identity?
        each_head(Index::TopLevel.new, name, path) do |head|
          return head if declared?(head, :lexical)
        end
        nil
      end

      private def through_alias(identity : Index::Identity, scope : Scope) : Index::Identity
        aliases = @workspace.aliases(identity)
        return identity if aliases.empty?

        candidates = loaded(aliases)
        targets = candidates.map(&.target).uniq!
        return identity unless targets.size == 1

        target = targets[0]
        return identity unless target.is_a?(Syntax::Named)

        owner_scope = Scope.new(
          identity.parent, Array(String).new, Array(Binding).new, candidates[0].path
        )
        resolved = resolve_named(target, owner_scope, [identity], :lexical)
        resolved.is_a?(TypeRef) ? resolved.identity : identity
      end

      private def search_in(
        namespace : Index::Owner,
        lookup : Lookup,
        & : Index::Owner ->
      ) : Nil
        yield namespace
        return unless namespace.is_a?(Index::Identity) && lookup.ancestors?

        chain = @ancestors.of(namespace, self)
        return if chain.is_a?(Unknown)

        chain.each { |ancestor| yield ancestor }
      end

      private def each_head(
        namespace : Index::Owner,
        name : String,
        path : String?,
        & : Index::Identity ->
      ) : Nil
        case namespace
        in Index::TopLevel
          yield Index::FilePrivate.new(name, path) if path && @workspace.private_to?(path)
          yield Index::Public.new(name)
        in Index::Identity
          yield namespace.child(name)
        end
      end

      private def resolve_named(
        type : Syntax::Named,
        scope : Scope,
        visiting : Array(Index::Identity),
        lookup : Lookup,
      ) : Resolution
        if type.names.size == 1 && !type.global?
          name = type.names[0]
          bound = scope.bound(name)
          return bound if bound
          return TypeVar.new(name) if scope.type_vars.includes?(name)
        end

        located = locate(type, scope, lookup)
        if located.is_a?(Unknown)
          inherited = inherited_type_var(type, scope) if located.reason.unresolved_name?
          return inherited || located
        end

        follow(located, visiting, lookup)
      end

      private def inherited_type_var(type : Syntax::Named, scope : Scope) : Resolution?
        return if type.names.size != 1 || type.global?

        owner = scope.namespace
        return unless owner.is_a?(Index::Identity)
        return if @inheriting.includes?(owner)

        @inheriting << owner
        begin
          inherited_type_var(type.names[0], owner, scope)
        ensure
          @inheriting.pop
        end
      end

      private def inherited_type_var(
        name : String,
        owner : Index::Identity,
        scope : Scope,
      ) : Resolution?
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
        full : Index::Identity,
        visiting : Array(Index::Identity),
        lookup : Lookup,
      ) : Resolution
        aliases = @workspace.aliases(full)
        return named(full) if aliases.empty?
        return named(full) if visiting.includes?(full) || @following.includes?(full)

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

        declaring = Scope.of(full.parent, candidates[0].path)
        @following << full
        begin
          if target.is_a?(Syntax::Named)
            resolve_named(target, declaring, visiting + [full], lookup)
          else
            resolve(target, declaring, lookup)
          end
        ensure
          @following.pop
        end
      end

      private def loaded(aliases : Array(Index::Alias)) : Array(Index::Alias)
        known = aliases.select { |entry| @compiled.known?(entry.path) }
        known.empty? ? aliases : known
      end

      private def named(identity : Index::Identity) : TypeRef
        TypeRef.new(identity, Array(Resolution).new, bare: identity == CoreType::Tuple.identity)
      end

      private def declared?(identity : Index::Identity, lookup : Lookup) : Bool
        return true unless @workspace.namespaces(identity).empty?
        return true unless @workspace.aliases(identity).empty?
        return true if @workspace.encloses?(identity)
        return true if lookup.constants? && !@workspace.constants(identity).empty?

        case identity
        in Index::Public
          name = identity.name
          (lookup.constants? && Builtins.constant?(name)) ||
            (!name.includes?("::") && Builtins.includes?(name))
        in Index::FilePrivate then false
        end
      end

      private def resolve_generic(
        type : Syntax::Generic,
        scope : Scope,
        lookup : Lookup,
      ) : Resolution
        base = resolve_named(type.base, scope, Array(Index::Identity).new, lookup)
        return base unless base.is_a?(TypeRef)
        unless type.named_arguments.empty?
          unless type.arguments.empty? && base.is?(:named_tuple)
            return Unknown.new(:unsupported, "named type arguments in #{type}")
          end

          labelled = Array(Resolution).new(type.named_arguments.size)
          type.named_arguments.each do |argument|
            labelled << resolve(argument.type, scope, lookup)
          end
          return TypeRef.new(base.identity, labelled, type.named_arguments.map(&.name))
        end

        arguments = Array(Resolution).new(type.arguments.size)
        type.arguments.each do |argument|
          if argument.is_a?(Syntax::Splat)
            pack = splat_pack(argument, scope)
            return unpacked(argument, scope) unless pack

            arguments.concat(pack.arguments)
          else
            arguments << resolve(argument, scope, lookup)
          end
        end
        return union_of(arguments) if base.is?(:union)

        TypeRef.new(base.identity, arguments)
      end

      private def resolve_proc(
        type : Syntax::Proc,
        scope : Scope,
        lookup : Lookup,
      ) : Resolution
        arguments = Array(Resolution).new(type.inputs.size + 1)
        type.inputs.each { |input| arguments << resolve(input, scope, lookup) }
        output = type.output
        arguments << if output
          resolve(output, scope, lookup)
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

      private def unpacked(type : Syntax::Splat, scope : Scope) : Unknown
        spread = resolve_splat(type, scope)
        return spread if spread.is_a?(Unknown)

        Unknown.new(:unsupported, "#{type} is bound to #{spread}, not a tuple")
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
        lookup : Lookup,
      ) : Resolution
        resolve_union([type.inner, NIL] of Syntax::Type, scope, lookup)
      end

      private def resolve_union(
        members : Array(Syntax::Type),
        scope : Scope,
        lookup : Lookup,
      ) : Resolution
        resolved = Array(Resolution).new(members.size)
        members.each do |member|
          resolution = resolve(member, scope, lookup)
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
        lookup : Lookup,
      ) : Resolution
        inner = resolve(type.of, scope, lookup)
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
        in Index::Identity
          arguments = type_vars_of(namespace).compact_map { |type_var| scope.bound(type_var) }
          TypeRef.new(namespace, arguments)
        end
      end
    end
  end
end
