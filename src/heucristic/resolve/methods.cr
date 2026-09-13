require "./precision"
require "./compiled"
require "../index/def"
require "../index/workspace"
require "../syntax/type"
require "../syntax/well_known"
require "./types"

module Heucristic
  module Resolve
    class Methods
      record Rejected, index : Int32, expected : Resolution, actual : Resolved

      record Call,
        name : String,
        arity : Int32,
        block : Bool,
        arguments : Array(Resolution),
        named : Array(String),
        named_arguments : Array(Binding) = Array(Binding).new,
        implicit : Bool = false,
        caller_path : String? = nil,
        precisions : Array(Precision) = Array(Precision).new do
        def self.new(name : String, arity : Int32, block : Bool) : Call
          new(name, arity, block, Array(Resolution).new, Array(String).new)
        end

        def bound?(index : Int32) : Bool
          precision = precisions[index]?
          precision.nil? || precision.bound?
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
          positional_satisfied?(entry) && entry.yields == block && keywords_satisfied?(entry)
        end

        def complaint(entry : Index::Def) : String?
          positional = entry.parameters.select(&.kind.positional?)
          accepts_any = entry.parameters.any?(&.kind.double_splat?)
          named.each do |name|
            index = positional.index(&.external_name.==(name))
            return "argument for parameter '#{name}' already specified" if index && index < arity
            next if index || entry.parameters.any? { |parameter| keyword_named?(parameter, name) }
            return "no parameter named '#{name}'" unless accepts_any
          end
          entry.parameters.each do |parameter|
            next unless parameter.kind.keyword? && parameter.default.nil?
            next if named.includes?(parameter.external_name)

            return "missing argument: #{parameter.external_name}"
          end
          positional.each_with_index do |parameter, index|
            next if index < arity || parameter.default || named.includes?(parameter.external_name)

            return "missing argument: #{parameter.external_name}"
          end
          nil
        end

        private def keyword_named?(parameter : Index::Parameter, name : String) : Bool
          parameter.kind.keyword? && parameter.external_name == name
        end

        private def positional_satisfied?(entry : Index::Def) : Bool
          positional = entry.parameters.select(&.kind.positional?)
          by_name = positional.count { |parameter| named.includes?(parameter.external_name) }
          required = positional.count { |parameter| parameter.default.nil? }
          required_by_name = positional.count do |parameter|
            parameter.default.nil? && named.includes?(parameter.external_name)
          end
          return false if arity + by_name > positional.size && !entry.arity.splat

          arity >= required - required_by_name
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

      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
        @including = Array(String).new
        @includers = Hash(String, Array(String)).new
        @private_paths = Hash(String, Array(String)).new
        @compiled = Compiled::NONE
      end

      def compiled(map : Compiled) : Nil
        @compiled = map
      end

      def invalidate : Nil
        @includers.clear
        @private_paths.clear
      end

      def compatible?(entry : Index::Def, call : Call) : Bool
        rejected_argument(entry, call).nil?
      end

      def rejected_argument(entry : Index::Def, call : Call, any_member : Bool = false) : Rejected?
        positional = entry.parameters.select(&.kind.positional?)
        owner = entry.owner
        owner_vars = owner.is_a?(String) ? @types.type_vars_of(owner) : Array(String).new
        type_vars = entry.free_vars + owner_vars
        scope = Scope.new(owner, type_vars, Array(Binding).new, entry.path)
        splat = entry.parameters.find(&.kind.splat?)
        call.arguments.each_with_index do |argument, index|
          parameter = positional[index]? || splat
          restriction = parameter.try(&.restriction)
          next if argument.is_a?(Unknown) || !restriction.is_a?(Syntax::Type)

          expected = @types.resolve_lexically(restriction, scope)
          next if admits?(expected, argument)
          next if any_member && argument.is_a?(UnionRef) && call.bound?(index) &&
                  admits_any?(expected, argument)

          return Rejected.new(index, expected, argument)
        end
        nil
      end

      def lookup(receiver : Resolution, call : Call) : Array(Index::Def)
        found = case receiver
                in TypeRef          then instance_methods(receiver.name, call)
                in MetaRef          then metaclass_methods(receiver.of, call)
                in UnionRef         then union_methods(receiver, call)
                in TypeVar, Unknown then Array(Index::Def).new
                end
        return found unless found.empty? && call.implicit

        top_level(call)
      end

      def candidates(receiver : Resolved) : Array(Index::Def)
        case receiver
        in TypeRef  then instance_candidates(receiver.name)
        in MetaRef  then metaclass_candidates(receiver.of)
        in UnionRef then union_candidates(receiver)
        in TypeVar  then instance_candidates(CoreType::Object.type_name)
        end
      end

      def named_on(
        receiver : Resolved,
        name : String,
        caller_path : String? = nil,
      ) : Array(Index::Def)
        found = case receiver
                in TypeRef then instance_named(receiver.name, name)
                in MetaRef
                  of = receiver.of
                  of.is_a?(TypeVar) ? Array(Index::Def).new : metaclass_named(of.name, name)
                in UnionRef, TypeVar then Array(Index::Def).new
                end
        found.select { |entry| own?(entry, caller_path) }
      end

      def own?(entry : Index::Def, caller_path : String?) : Bool
        return true unless caller_path
        return false unless reachable?(entry, caller_path)

        owner = entry.owner
        return true unless owner.is_a?(String)

        privately = private_paths(owner)
        return true unless privately.includes?(caller_path)

        entry.path == caller_path
      end

      def levels(type : String) : Array(String)
        chain = @types.ancestors(type)
        found = chain.is_a?(Unknown) ? [type] : [type] + chain
        object = CoreType::Object.type_name
        found << object if module?(type) && !found.includes?(object)
        found
      end

      def admits?(restriction : Resolution, argument : Resolved) : Bool
        if argument.is_a?(UnionRef)
          return argument.members.all? do |member|
            member.is_a?(Unknown) || admits?(restriction, member)
          end
        end

        case restriction
        in Unknown, TypeVar then true
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
          in MetaRef  then restriction.is?(:class) || module?(restriction.name)
          in TypeVar  then true
          end
        end
      end

      def lookup_super(receiver : Resolved, owner : String, call : Call) : Array(Index::Def)
        case receiver
        in TypeRef
          first_level(receiver.name, call, after: owner) do |entry|
            entry.receiver.instance? && call.accepts?(entry) && compatible?(entry, call)
          end
        in MetaRef
          of = receiver.of
          return Array(Index::Def).new if of.is_a?(TypeVar)

          first_level(of.name, call, after: owner) do |entry|
            entry.receiver.metaclass? && call.accepts?(entry) && compatible?(entry, call)
          end
        in UnionRef, TypeVar then Array(Index::Def).new
        end
      end

      private def admits_any?(expected : Resolution, argument : UnionRef) : Bool
        argument.members.any? do |member|
          member.is_a?(Unknown) || admits?(expected, member)
        end
      end

      private def reachable?(entry : Index::Def, caller_path : String) : Bool
        return true unless @compiled.project?(entry.path) && @compiled.known?(caller_path)

        @compiled.shared?(caller_path, entry.path)
      end

      private def private_paths(owner : String) : Array(String)
        @private_paths[owner] ||= @workspace.namespaces(owner).compact_map(&.private_path)
      end

      private def autocast?(argument : TypeRef, restriction : TypeRef) : Bool
        return false unless argument.is?(:symbol)

        @workspace.namespaces(restriction.name).any?(Index::EnumNamespace)
      end

      private def ancestor?(type : String, candidate : String) : Bool
        chain = @types.ancestors(type)
        chain.is_a?(Unknown) || chain.includes?(candidate)
      end

      private def instance_methods(type : String, call : Call) : Array(Index::Def)
        found = first_level(type, call) do |entry|
          entry.receiver.instance? && call.accepts?(entry) && compatible?(entry, call)
        end
        return found unless found.empty?

        found = first_level(type, call) { |entry| entry.receiver.instance? && call.accepts?(entry) }
        found.empty? ? includer_methods(type, call) : found
      end

      private def includer_methods(type : String, call : Call) : Array(Index::Def)
        return Array(Index::Def).new if @including.includes?(type)
        return Array(Index::Def).new unless @workspace.namespaces(type).any?(Index::ModuleNamespace)

        @including << type
        found = Array(Index::Def).new
        includers_of(type).each { |includer| found.concat(instance_methods(includer, call)) }
        @including.pop
        found.uniq!
      end

      private def includers_of(type : String) : Array(String)
        cached = @includers[type]?
        return cached if cached

        @includers[type] = compute_includers(type)
      end

      private def compute_includers(type : String) : Array(String)
        names = Array(String).new
        @workspace.each_mixin do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)
          owner = mixin.owner
          next unless owner.is_a?(String)

          scope = Scope.new(owner, @types.type_vars_of(owner))
          resolved = @types.resolve_lexically(target, scope)
          names << owner if resolved.is_a?(TypeRef) && resolved.name == type
        end
        names.uniq!
      end

      private def class_methods(type : String, call : Call) : Array(Index::Def)
        found = first_level(type, call) do |entry|
          entry.receiver.metaclass? && call.accepts?(entry) && compatible?(entry, call)
        end
        return found unless found.empty?

        extended = extended_methods(type, call)
        return extended unless extended.empty?

        if Syntax::WellKnown::New.named?(call.name)
          constructor = Call.new(
            Syntax::WellKnown::Initialize.method_name,
            call.arity,
            call.block,
            call.arguments,
            call.named,
            call.named_arguments,
          )
          constructed = instance_methods(type, constructor)
          return constructed unless constructed.empty?

          implicit = default_constructor(type, call)
          return implicit unless implicit.empty?
        end

        first_level(type, call) { |entry| entry.receiver.metaclass? && call.accepts?(entry) }
      end

      private def union_methods(receiver : UnionRef, call : Call) : Array(Index::Def)
        receiver.members.flat_map { |member| lookup(member, call) }.uniq!
      end

      private def union_candidates(receiver : UnionRef) : Array(Index::Def)
        receiver.members.flat_map do |member|
          member.is_a?(Resolved) ? candidates(member) : Array(Index::Def).new
        end
      end

      private def instance_candidates(type : String) : Array(Index::Def)
        found = Array(Index::Def).new
        levels(type).each do |level|
          @workspace.defs_of(level).each { |entry| found << entry if entry.receiver.instance? }
        end
        found.concat(includers_candidates(type)) if found.empty?
        found
      end

      private def includers_candidates(type : String) : Array(Index::Def)
        return Array(Index::Def).new unless @workspace.namespaces(type).any?(Index::ModuleNamespace)

        includers_of(type).flat_map { |includer| instance_candidates(includer) }
      end

      private def metaclass_candidates(of : TypeRef | TypeVar) : Array(Index::Def)
        return instance_candidates(CoreType::Class.type_name) if of.is_a?(TypeVar)

        found = Array(Index::Def).new
        levels(of.name).each do |level|
          @workspace.defs_of(level).each { |entry| found << entry if entry.receiver.metaclass? }
        end
        found.concat(instance_candidates(CoreType::Class.type_name))
        found
      end

      private def metaclass_methods(of : TypeRef | TypeVar, call : Call) : Array(Index::Def)
        return class_methods(CoreType::Object.type_name, call) if of.is_a?(TypeVar)

        found = class_methods(of.name, call)
        found.empty? ? instance_methods(CoreType::Class.type_name, call) : found
      end

      private def top_level(call : Call) : Array(Index::Def)
        candidates = @workspace.named(call.name).select do |entry|
          entry.owner.is_a?(Index::TopLevel) && entry.visible_from?(call.caller_path) &&
            own?(entry, call.caller_path) && call.accepts?(entry) && compatible?(entry, call)
        end
        own = candidates.reject(&.private_path.nil?)
        candidates = own unless own.empty?
        return most_specific(candidates, call) unless candidates.empty?

        mixed_in_at_top_level(call)
      end

      private def mixed_in_at_top_level(call : Call) : Array(Index::Def)
        found = Array(Index::Def).new
        @workspace.mixins_of(Index::TopLevel.new).each do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)

          resolved = @types.resolve_lexically(target, Scope::TOP)
          found.concat(instance_methods(resolved.name, call)) if resolved.is_a?(TypeRef)
        end
        found.uniq!
      end

      private def module?(type : String) : Bool
        @workspace.namespaces(type).any?(Index::ModuleNamespace)
      end

      private def default_constructor(type : String, call : Call) : Array(Index::Def)
        return Array(Index::Def).new if call.arity > 0 || call.block || !call.named.empty?

        searched = levels(type)
        initialize = Syntax::WellKnown::Initialize.method_name
        declared = @workspace.named(initialize).any? { |entry| searched.includes?(entry.owner) }
        return Array(Index::Def).new if declared

        entry = @workspace.namespaces(type).select(Index::ClassNamespace).first?
        return Array(Index::Def).new unless entry

        [Index::Def.new(
          name: Syntax::WellKnown::New.method_name,
          owner: type,
          receiver: :metaclass,
          path: entry.path,
          name_span: entry.name_span,
          arity: Index::Arity.new(0, 0, false),
          parameters: Array(Index::Parameter).new,
          return_type: Syntax::SelfType.new,
          free_vars: Array(String).new,
          yields: false,
        )]
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
        return owner if target.is_a?(Syntax::SelfType)

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
          found = candidates.select do |entry|
            entry.owner == level && own?(entry, call.caller_path) && yield entry
          end
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

      private def instance_named(type : String, name : String) : Array(Index::Def)
        searched = levels(type)
        found = @workspace.named(name).select do |entry|
          entry.receiver.instance? && searched.includes?(entry.owner)
        end
        return found unless found.empty?
        return found if @including.includes?(type)
        return found unless @workspace.namespaces(type).any?(Index::ModuleNamespace)

        @including << type
        includers_of(type).each { |includer| found.concat(instance_named(includer, name)) }
        @including.pop
        found.uniq!
      end

      private def metaclass_named(type : String, name : String) : Array(Index::Def)
        searched = levels(type)
        found = @workspace.named(name).select do |entry|
          entry.receiver.metaclass? && searched.includes?(entry.owner)
        end
        searched.each do |level|
          @workspace.mixins_of(level).each do |mixin|
            next unless mixin.kind.extend?

            module_name = extended_module(mixin, level)
            found.concat(instance_named(module_name, name)) if module_name
          end
        end
        found.concat(instance_named(CoreType::Class.type_name, name))
        found.concat(constructors(type)) if Syntax::WellKnown::New.named?(name)
        found.uniq!
      end

      private def constructors(type : String) : Array(Index::Def)
        levels(type).each do |level|
          declared = @workspace.named(Syntax::WellKnown::Initialize.method_name).select do |entry|
            entry.receiver.instance? && entry.owner == level
          end
          return declared unless declared.empty?
        end
        default_constructor(type, Call.new(Syntax::WellKnown::New.method_name, 0, false))
      end
    end
  end
end
