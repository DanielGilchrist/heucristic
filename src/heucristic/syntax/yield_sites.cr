require "compiler/crystal/syntax"
require "./scoped"

module Heucristic
  module Syntax
    class YieldSites < Scoped
      record Site, node : Crystal::Yield, context : Context

      getter sites : Array(Site)

      def self.in(
        definition : Crystal::Def,
        enclosing : Array(String),
        type_vars : Array(String),
      ) : Array(Site)
        finder = new(enclosing, type_vars, definition)
        definition.body.accept(finder)
        finder.sites
      end

      def initialize(
        enclosing : Array(String),
        type_vars : Array(String),
        definition : Crystal::Def,
      ) : Nil
        super
        @sites = Array(Site).new
      end

      def visit(node : Crystal::Yield) : Bool
        @sites << Site.new(node, context)
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end
    end
  end
end
