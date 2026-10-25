require "compiler/crystal/syntax"
require "../index/sites"
require "./finding"

module Heucristic
  module Check
    struct Controls
      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        sites.controls.each { |site| check(site, sites.text, findings) }
      end

      private def check(
        site : Syntax::Uses::ControlSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        node = site.node
        inside_def = site.context.method_body?
        looped = looped?(site.context.ancestors)
        message = case site.kind
                  in .yield?  then inside_def ? nil : "can't use `yield` outside a method"
                  in .return? then inside_def ? nil : "can't return from top level"
                  in .break?  then looped ? nil : "invalid break"
                  in .next?   then looped ? nil : "invalid next"
                  end
        return unless message
        return if site.context.ancestors.any?(Crystal::ProcLiteral)
        location = node.location
        return unless location

        start = Document::Point.from(location)
        span = text.span(start, start.advance(site.kind.keyword.size))
        return unless span.is_a?(Document::Span)

        findings << Finding.new(:misplaced_control, message, span)
      end

      private def looped?(ancestors : Array(Crystal::ASTNode)) : Bool
        boundary = ancestors.rindex(&.is_a?(Crystal::Def)) || -1
        ancestors[(boundary + 1)..].any? do |node|
          node.is_a?(Crystal::While) || node.is_a?(Crystal::Until) || node.is_a?(Crystal::Block)
        end
      end
    end
  end
end
