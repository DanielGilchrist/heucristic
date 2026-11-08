require "compiler/crystal/syntax"
require "../index/def"
require "../index/macro_hook"
require "../index/shims"
require "../index/workspace"
require "../syntax/type"
require "./binding"
require "./methods"
require "./resolution"
require "./typer"
require "./unions"
require "./visit"

module Heucristic
  module Resolve
    class Dispatch
      module Typer
        include Resolve::Typer

        abstract def return_type(
          entry : Index::Def,
          receiver : Resolved,
          arguments : Array(Resolution),
          site : Receiver::Site,
        ) : Resolution
      end

      record Locus, path : String, line : UInt32

      record DefinitionKey, loci : Array(Locus) do
        def self.of(defs : Array(Index::Def)) : DefinitionKey
          new(defs.map { |entry| Locus.new(entry.path, entry.name_span.start_line) })
        end
      end

      def initialize(
        @workspace : Index::Workspace,
        @methods : Methods,
        @shims : Index::Shims,
        @unions : Unions,
        @typer : Typer,
      ) : Nil
      end

      def result(
        receiver : Resolved,
        call : Methods::Call,
        site : Receiver::Site = Receiver::Site::NONE,
      ) : Resolution
        if receiver.is_a?(UnionRef)
          members = receiver.members.map do |member|
            member.is_a?(Unknown) ? member : result(member, call, site)
          end
          return @unions.union(members)
        end

        if receiver.is_a?(TypeVar)
          return Unknown.new(
            :free_variable,
            "#{receiver} is a type variable; `#{call.name}` depends on its instantiation",
          )
        end
        return receiver if receiver.is_a?(TypeRef) && receiver.is?(:no_return)
        if receiver.is_a?(MetaRef) && call.name == "|"
          other = call.arguments[0]?
          return UnionRef.new([receiver, other] of Resolution) if other.is_a?(MetaRef)
        end

        defs = @methods.lookup(receiver, call)
        if defs.empty? && receiver.is_a?(MetaRef) && (variable = receiver.of).is_a?(TypeVar)
          return Unknown.new(
            :free_variable,
            "#{variable} is a type variable; `#{call.name}` depends on its instantiation",
          )
        end
        if defs.empty? && (forwarded = missing_forward(receiver, call, site))
          return forwarded
        end
        return virtual(receiver, call, site) if defs.empty?

        direct = overloads(defs, receiver, call, site)
        through_subclasses(defs, direct, receiver, call, site)
      end

      def forwarded_receiver(receiver : Resolved) : Resolution?
        handler = missing_handler(receiver)
        forward_receiver(handler, Array(Visit){DefVisit.new(handler.qualified)}) if handler
      end

      def overridden?(below : Resolved, receiver : TypeRef, call : Methods::Call) : Bool
        return true unless below.is_a?(TypeRef)

        @methods.defined_between?(below.name, receiver.name, call.name)
      end

      private def missing_forward(
        receiver : Resolved,
        call : Methods::Call,
        site : Receiver::Site,
      ) : Resolution?
        handler = missing_handler(receiver)
        return unless handler
        visit = DefVisit.new(handler.qualified)
        return visit.cycle if site.visiting.includes?(visit)

        visiting = site.visiting + [visit]
        delegate = forward_receiver(handler, visiting)
        return delegate if delegate.is_a?(Unknown)

        result(delegate, call, Receiver::Site.new(site.block, site.context, site.locals, visiting))
      end

      private def missing_handler(receiver : Resolved) : Index::Def?
        return unless receiver.is_a?(TypeRef)

        levels = @methods.levels(receiver.name)
        @workspace.named(Index::MacroHook::MethodMissing.macro_name).find do |entry|
          owner = entry.owner
          !entry.forwards_to.nil? && owner.is_a?(String) && levels.includes?(owner)
        end
      end

      private def forward_receiver(handler : Index::Def, visiting : Array(Visit)) : Resolution
        target = handler.forwards_to
        return Unknown.new(:unresolved_name, handler.qualified) unless target

        owner = handler.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        context = Syntax::Context.new(enclosing, Array(String).new, nil, handler.path, true)
        @typer.type_of(target, context, visiting, Array(Binding).new)
      end

      private def virtual(
        receiver : Resolved,
        call : Methods::Call,
        site : Receiver::Site,
      ) : Resolution
        concrete = @methods.virtual_receivers(receiver, call.caller_path)
        if concrete.empty?
          return @methods.missing(call.name, receiver)
        end

        results = Array(Resolution).new(concrete.size)
        concrete.each do |below|
          if @methods.lookup(below, call).empty?
            return Unknown.new(
              :unresolved_name, "no `#{call.name}` on #{below}, a subclass of #{receiver}"
            )
          end
          results << result(below, call, site)
        end
        @unions.union(results)
      end

      private def overloads(
        defs : Array(Index::Def),
        receiver : Resolved,
        call : Methods::Call,
        site : Receiver::Site,
      ) : Resolution
        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << @typer.return_type(entry, receiver, call.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1
        if call.arguments.empty? && !call.block
          annotated = distinct.reject do |candidate|
            candidate.is_a?(Unknown) && candidate.reason.no_annotation?
          end
          return annotated[0] if annotated.size == 1
        end
        module_receiver = receiver.is_a?(TypeRef) && @workspace.module?(receiver.name)
        return @unions.union(results) if module_receiver

        Unknown.new(:ambiguous, "#{defs.size} overloads of `#{call.name}` do not agree on a type")
      end

      private def through_subclasses(
        defs : Array(Index::Def),
        direct : Resolution,
        receiver : Resolved,
        call : Methods::Call,
        site : Receiver::Site,
      ) : Resolution
        return direct unless receiver.is_a?(TypeRef)

        subclasses = @methods.concrete_subclasses(receiver, call.caller_path)
        return direct if subclasses.empty?

        key = DispatchVisit.new(receiver, call.name, call.arity)
        return key.cycle if site.visiting.includes?(key)

        virtual_only = @methods.abstract_class?(receiver.name)
        selfish = defs.any? { |entry| self_typed?(entry) }
        results = Array(Resolution).new
        results << direct unless virtual_only
        seen = Set(DefinitionKey).new
        seen << DefinitionKey.of(defs) unless virtual_only
        inner = site.copy_with(visiting: site.visiting + [key])
        subclasses.each do |below|
          unless selfish || overridden?(below, receiver, call)
            results << direct if seen.add?(DefinitionKey.of(defs))
            next
          end

          below_defs = @methods.lookup(below, call)
          next if below_defs.empty?
          next unless selfish || seen.add?(DefinitionKey.of(below_defs))

          outcome = overloads(below_defs, below, call, inner)
          next if outcome == key.cycle

          results << outcome
        end
        return direct if results.empty?

        @unions.union(results)
      end

      private def self_typed?(entry : Index::Def) : Bool
        restriction = entry.return_type
        shim = @shims.find(entry)
        restriction = shim.return_type if shim && restriction.is_a?(Index::Unrestricted)
        restriction.is_a?(Syntax::Type) && Syntax::SelfType.within?(restriction)
      end
    end
  end
end
