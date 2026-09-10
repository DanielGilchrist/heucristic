require "compiler/crystal/syntax"
require "./scoped"

module Heucristic
  module Syntax
    class Calls < Scoped
      record Site, call : Crystal::Call, context : Context

      getter sites : Array(Site)

      def self.in(tree : Crystal::ASTNode, path : String?) : Array(Site)
        calls = new(path)
        tree.accept(calls)
        calls.sites
      end

      def initialize(path : String?) : Nil
        super(path)
        @sites = Array(Site).new
      end

      def visit(node : Crystal::Call) : Bool
        @sites << Site.new(node, context) if node.name_location
        super
      end
    end
  end
end
