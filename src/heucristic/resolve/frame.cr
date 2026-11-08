require "compiler/crystal/syntax"
require "../syntax/context"
require "./binding"
require "./visit"

module Heucristic
  module Resolve
    record Frame,
      context : Syntax::Context,
      locals : Array(Binding),
      visiting : Array(Visit) do
      def self.of(context : Syntax::Context) : Frame
        new(context, Array(Binding).new, Array(Visit).new)
      end

      def untracked? : Bool
        locals.empty? && visiting.empty?
      end

      def within(other : Syntax::Context) : Frame
        Frame.new(other, locals, visiting)
      end

      def inside(parent : Crystal::ASTNode, child : Crystal::ASTNode) : Frame
        within(context.inside(parent, child))
      end

      def at(path : Array(Crystal::ASTNode)) : Frame
        within(context.at(path))
      end

      def visited(visit : Visit) : Frame
        Frame.new(context, locals, visiting + [visit])
      end

      def with_locals(replacement : Array(Binding)) : Frame
        Frame.new(context, replacement, visiting)
      end

      def with_visiting(replacement : Array(Visit)) : Frame
        Frame.new(context, locals, replacement)
      end
    end
  end
end
