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

module Heucristic
  module Check
    struct Returns
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
        return unless checkable?(expected)

        returned(node, site, sites).each do |actual|
          next if actual.is_a?(Resolve::Unknown) || admitted?(expected, actual)

          start = Document::Point.from(location)
          span = sites.text.span(start, start.advance(node.name.size))
          return unless span.is_a?(Document::Span)

          message = String.build do |io|
            io << "method " << qualified(node, context) << " must return " << expected
            io << " but it is returning " << actual
          end
          findings << Finding.new(:return_mismatch, message, span)
          return
        end
      end

      private def checkable?(expected : Resolve::Resolution) : Bool
        case expected
        in Resolve::TypeRef
          !(expected.is?(:nil) || expected.is?(:no_return) || expected.name == "Void")
        in Resolve::UnionRef
          expected.members.all?(Resolve::TypeRef)
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown then false
        end
      end

      private def admitted?(expected : Resolve::Resolution, actual : Resolve::Resolved) : Bool
        return true if actual.is_a?(Resolve::TypeRef) && actual.is?(:no_return)
        return true if actual.is_a?(Resolve::TypeVar) || actual.is_a?(Resolve::MetaRef)
        if actual.is_a?(Resolve::UnionRef)
          return actual.members.any? do |member|
            member.is_a?(Resolve::Unknown) || admitted?(expected, member)
          end
        end

        @methods.admits?(expected, actual)
      end

      private def returned(
        node : Crystal::Def,
        site : Syntax::Uses::DefSite,
        sites : Index::Sites,
      ) : Array(Resolve::Resolution)
        values = Array(Resolve::Resolution).new
        body = node.body
        values << body_value(body, site.context.inside(node, body))
        sites.controls.each do |control|
          next unless control.kind.return? && control.context.def_node.try(&.same?(node))
          next if control.context.ancestors.any?(Crystal::ProcLiteral)

          exp = control.node.as?(Crystal::Return).try(&.exp)
          values << returned_value(exp, control.context)
        end
        values
      end

      private def returned_value(
        exp : Crystal::ASTNode?,
        context : Syntax::Context,
      ) : Resolve::Resolution
        return Resolve::TypeRef.of(:nil) unless exp

        @receiver.typed(exp, context.inside(exp))
      end

      private def body_value(
        body : Crystal::ASTNode,
        context : Syntax::Context,
      ) : Resolve::Resolution
        return Resolve::TypeRef.of(:nil) if body.is_a?(Crystal::Nop)
        return Resolve::TypeRef.of(:nil) if empty_expressions?(body)

        @receiver.typed(body, context)
      end

      private def empty_expressions?(body : Crystal::ASTNode) : Bool
        body.is_a?(Crystal::Expressions) && body.expressions.empty?
      end

      private def qualified(node : Crystal::Def, context : Syntax::Context) : String
        owner = context.owner
        return "::#{node.name}" if owner.is_a?(Index::TopLevel)

        "#{owner}#{node.receiver ? "." : "#"}#{node.name}"
      end
    end
  end
end
