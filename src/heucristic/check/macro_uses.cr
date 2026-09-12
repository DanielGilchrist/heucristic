require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../index/accessor"
require "../index/synthesized"

module Heucristic
  module Check
    class MacroUses < Crystal::Visitor
      def self.any?(sites : Index::Sites, workspace : Index::Workspace) : Bool
        invoked = sites.calls.any? do |site|
          call = site.call
          next false unless call.obj.nil?
          next false if Index::Accessor.from_name(call.name)
          next false if Index::Synthesized.from_name(call.name)

          !workspace.macros(call.name).empty?
        end
        return true if invoked

        visitor = new
        sites.tree.accept(visitor)
        visitor.found?
      end

      getter? found : Bool

      def initialize : Nil
        @found = false
      end

      def visit(node : Crystal::MacroExpression | Crystal::MacroFor | Crystal::MacroIf) : Bool
        @found = true
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        !@found
      end
    end
  end
end
