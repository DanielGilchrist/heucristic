require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/types"
require "../resolve/scope"
require "./finding"
require "./settled"
require "./macro_arguments"

module Heucristic
  module Check
    struct Paths
      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @settled : Settled,
      ) : Nil
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        return unless @settled.program?

        sites.paths.each { |site| check(site, sites.text, findings) }
      end

      private def check(
        site : Syntax::Uses::PathSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        path = site.path
        location = path.location
        return unless location
        return if MacroArguments.within?(site.context.ancestors, @workspace)
        return if site.context.blocks.any? do |block_call|
                    block_call.obj.nil? && Syntax::WellKnown::Pending.named?(block_call.name)
                  end
        return if inside_lib?(site.context)

        scope = Resolve::Scope.of(site.context)
        named = Syntax::Named.new(path.names, path.global?)
        located = @types.locate_any(named, scope)
        return unless located.is_a?(Resolve::Unknown) && located.reason.unresolved_name?
        resolved = @types.resolve_lexically(named, scope)
        return unless resolved.is_a?(Resolve::Unknown) && resolved.reason.unresolved_name?
        return unless provable?(path, scope)

        start = Document::Point.from(location)
        span = text.span(start, start.advance(path.to_s.size))
        return unless span.is_a?(Document::Span)

        findings << Finding.new(:undefined_constant, "undefined constant #{path}", span)
      end

      private def provable?(path : Crystal::Path, scope : Resolve::Scope) : Bool
        return false if @workspace.namespaces(path.names[0]).any?(Index::LibNamespace)
        return enclosing_settled?(scope) if path.names.size == 1

        head = @types.locate_any(Syntax::Named.new(path.names[0...-1], path.global?), scope)
        return false if head.is_a?(Resolve::Unknown)
        return false if @workspace.namespaces(head).any?(Index::LibNamespace)

        @settled.namespace?(head)
      end

      private def enclosing_settled?(scope : Resolve::Scope) : Bool
        scope.chain.all? do |owner|
          owner.is_a?(Index::TopLevel) || @settled.namespace?(owner)
        end
      end

      private def inside_lib?(context : Syntax::Context) : Bool
        context.enclosing.any? do |namespace|
          @workspace.namespaces(namespace).any?(Index::LibNamespace)
        end
      end
    end
  end
end
