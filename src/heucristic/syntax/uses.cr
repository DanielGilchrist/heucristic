require "compiler/crystal/syntax"
require "./scoped"

module Heucristic
  module Syntax
    class Uses < Scoped
      record CallSite, call : Crystal::Call, context : Context
      record PathSite, path : Crystal::Path, context : Context
      record CaseSite, node : Crystal::Case, context : Context

      getter calls : Array(CallSite)
      getter paths : Array(PathSite)
      getter cases : Array(CaseSite)

      def self.in(tree : Crystal::ASTNode, path : String?) : Uses
        uses = new(path)
        tree.accept(uses)
        uses
      end

      def initialize(path : String?) : Nil
        super(path)
        @calls = Array(CallSite).new
        @paths = Array(PathSite).new
        @cases = Array(CaseSite).new
      end

      def visit(node : Crystal::Case) : Bool
        @cases << CaseSite.new(node, context) if node.exhaustive? && node.location
        super
      end

      def visit(node : Crystal::Call) : Bool
        @calls << CallSite.new(node, context) if node.name_location
        super
      end

      def visit(node : Crystal::Path) : Bool
        @paths << PathSite.new(node, context) if node.location
        true
      end
    end
  end
end
