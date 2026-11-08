require "compiler/crystal/syntax"
require "../index/def"
require "../index/instance_var"
require "../index/workspace"
require "../syntax/type_reader"
require "./binding"
require "./resolution"
require "./scope"
require "./typer"
require "./types"
require "./unions"
require "./visit"

module Heucristic
  module Resolve
    class InstanceVarTypes
      def initialize(
        @workspace : Index::Workspace,
        @types : Types,
        @unions : Unions,
        @typer : Typer,
      ) : Nil
      end

      def of(name : String, context : Syntax::Context, visiting : Array(Visit)) : Resolution
        owner = context.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end

        levels = [owner]
        chain = @types.ancestors(owner)
        levels.concat(chain) unless chain.is_a?(Unknown)
        levels.each do |level|
          entries = @workspace.instance_vars_of(level).select(&.name.==(name))
          next if entries.empty?

          scope = scope_at(owner, level)
          return scope if scope.is_a?(Unknown)

          return from(entries, level, scope, visiting + [InstanceVarVisit.new(name)])
        end

        from_includers = includers(name, owner, visiting)
        return from_includers if from_includers

        Unknown.new(
          :no_annotation, "#{name} is never declared or assigned an evident type in #{owner}"
        )
      end

      def read(
        entry : Index::Def,
        name : String,
        visiting : Array(Visit),
        & : -> _
      ) : Resolution
        owner = entry.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end
        visit = DefVisit.new(entry.qualified)
        return visit.cycle if visiting.includes?(visit)

        inner = visiting + [visit]
        entries = @workspace.instance_vars_of(owner).select(&.name.==(name))
        if entries.empty?
          context = Syntax::Context.new([owner], @types.type_vars_of(owner), nil, entry.path)
          return of(name, context, inner)
        end

        scope = yield
        return scope if scope.is_a?(Unknown)

        from(entries, owner, scope, inner)
      end

      private def from(
        entries : Array(Index::InstanceVar),
        level : Index::Identity,
        scope : Scope,
        visiting : Array(Visit),
      ) : Resolution
        declared = entries.select(&.origin.declared?)
        unless declared.empty?
          typed = Array(Resolution).new(declared.size)
          declared.each { |entry| typed << @types.resolve(entry.type, scope.at(entry.path)) }
          return @unions.union(typed)
        end

        typed = Array(Resolution).new(entries.size)
        entries.each do |entry|
          type = entry.type
          if type.is_a?(Syntax::Type)
            typed << @types.resolve(type, scope.at(entry.path))
            next
          end

          expression = entry.expression
          next unless expression && guessable?(expression)

          context = Syntax::Context.new(
            [level], @types.type_vars_of(level), entry.definition, entry.path
          )
          guessed = @typer.type_of(expression, context, visiting, Array(Binding).new)
          typed << guessed unless guessed.is_a?(Unknown)
        end
        return @unions.union(typed) unless typed.empty?

        assigned = entries.map(&.type).select(Syntax::TypeReader::Unsupported).map(&.source)
        Unknown.new(
          :no_annotation,
          "#{entries[0].name} is only assigned #{assigned.join(", ")}; declare its type",
        )
      end

      private def guessable?(expression : Crystal::ASTNode) : Bool
        case expression
        in Crystal::Var, Crystal::Path then true
        in Crystal::Call               then expression.obj.is_a?(Crystal::Path)
        in Crystal::ASTNode            then false
        end
      end

      private def includers(
        name : String,
        owner : Index::Identity,
        visiting : Array(Visit),
      ) : Resolution?
        return unless @workspace.module?(owner)
        visit = IncluderVisit.new(owner)
        return if visiting.includes?(visit)

        found = Array(Resolution).new
        @workspace.each_mixin do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)
          includer = mixin.owner
          next unless includer.is_a?(Index::Identity)

          resolved = @types.resolve_lexically(target, Scope.of(includer, mixin.path))
          next unless resolved.is_a?(TypeRef) && resolved.identity == owner

          context = Syntax::Context.new([includer], Array(String).new, nil)
          resolution = of(name, context, visiting + [visit])
          found << resolution unless resolution.is_a?(Unknown)
        end
        return if found.empty?

        @unions.union(found)
      end

      private def scope_at(owner : Index::Identity, level : Index::Identity) : Scope | Unknown
        return Scope.new(owner, @types.type_vars_of(owner)) if level == owner

        this = TypeRef.new(owner, Array(Resolution).new)
        bindings = @types.bindings(this, level)
        return bindings if bindings.is_a?(Unknown)

        Scope.new(level, @types.type_vars_of(level), bindings)
      end
    end
  end
end
