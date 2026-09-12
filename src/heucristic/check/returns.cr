require "compiler/crystal/syntax"
require "../index/sites"
require "../index/body_traits"
require "../resolve/types"
require "../resolve/methods"
require "../resolve/receiver"
require "../resolve/scope"
require "../syntax/type_reader"
require "../syntax/well_known"
require "./finding"
require "./settled"
require "./fit"

module Heucristic
  module Check
    struct Returns
      record Returned, node : Crystal::ASTNode?, type : Resolve::Resolution

      def initialize(
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @settled : Settled,
      ) : Nil
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        return unless @settled.program?

        sites.defs.each { |site| check(site, sites, findings) }
      end

      private def check(
        site : Syntax::Uses::DefSite,
        sites : Index::Sites,
        findings : Array(Finding),
      ) : Nil
        node = site.node
        restriction = node.return_type
        location = node.name_location
        return unless restriction && location
        return if node.abstract? || Syntax::WellKnown::Initialize.named?(node.name)
        return if Index::BodyTraits.of(node).macro_body

        read = Syntax::TypeReader.read(restriction)
        return unless read.is_a?(Syntax::Type)
        return if read.is_a?(Syntax::SelfType)

        context = site.context
        scope = Resolve::Scope.new(
          context.owner, context.type_vars, Array(Resolve::Binding).new, context.path
        )
        expected = @types.resolve_lexically(read, scope)
        return unless Fit.new(@methods).checkable?(expected)

        returned(node, site, sites).each do |value|
          actual = value.type
          next if actual.is_a?(Resolve::Unknown) || Fit.new(@methods).fits?(expected, actual)

          span = span_for(value.node, node, sites.text)
          return unless span

          message = String.build do |io|
            io << "method " << qualified(node, context) << " must return " << expected
            io << " but it is returning " << actual
          end
          findings << Finding.new(:return_mismatch, message, span)
          return
        end
      end

      private def span_for(
        value : Crystal::ASTNode?,
        node : Crystal::Def,
        text : Document::Text,
      ) : Document::Span?
        location = value.try(&.location)
        unless value && location
          name_location = node.name_location
          return unless name_location

          start = Document::Point.from(name_location)
          span = text.span(start, start.advance(node.name.size))
          return span.is_a?(Document::Span) ? span : nil
        end

        start = Document::Point.from(location)
        finish = value.end_location
        stop = finish ? Document::Point.from(finish).advance(1) : start.advance(value.to_s.size)
        span = text.span(start, stop)
        span.is_a?(Document::Span) ? span : nil
      end

      private def returned(
        node : Crystal::Def,
        site : Syntax::Uses::DefSite,
        sites : Index::Sites,
      ) : Array(Returned)
        values = Array(Returned).new
        body = node.body
        leaves(body, site.context.inside(node, body), values)
        sites.controls.each do |control|
          next unless control.kind.return? && control.context.def_node.try(&.same?(node))
          next if control.context.ancestors.any?(Crystal::ProcLiteral)

          exp = control.node.as?(Crystal::Return).try(&.exp)
          if exp
            values << Returned.new(exp, @receiver.typed(exp, control.context.inside(exp)))
          else
            values << Returned.new(control.node, Resolve::TypeRef.of(:nil))
          end
        end
        values
      end

      private def leaves(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        values : Array(Returned),
      ) : Nil
        case node
        in Crystal::Nop then values << Returned.new(nil, Resolve::TypeRef.of(:nil))
        in Crystal::Expressions
          last = node.expressions.last?
          return values << Returned.new(nil, Resolve::TypeRef.of(:nil)) unless last

          leaves(last, context.inside(last), values)
        in Crystal::ExceptionHandler
          otherwise = node.else
          leaves(otherwise || node.body, context.inside(otherwise || node.body), values)
          node.rescues.try &.each do |handler|
            leaves(handler.body, context.inside(handler, handler.body), values)
          end
        in Crystal::If, Crystal::Unless
          leaves(node.then, context.inside(node.then), values)
          leaves(node.else, context.inside(node.else), values)
        in Crystal::Case
          node.whens.each do |branch|
            leaves(branch.body, context.inside(branch, branch.body), values)
          end
          otherwise = node.else
          leaves(otherwise, context.inside(otherwise), values) if otherwise
          return if otherwise || node.exhaustive?

          values << Returned.new(node, Resolve::TypeRef.of(:nil))
        in Crystal::ASTNode
          values << Returned.new(node, @receiver.typed(node, context))
        end
      end

      private def qualified(node : Crystal::Def, context : Syntax::Context) : String
        owner = context.owner
        return "::#{node.name}" if owner.is_a?(Index::TopLevel)

        "#{owner}#{node.receiver ? "." : "#"}#{node.name}"
      end
    end
  end
end
