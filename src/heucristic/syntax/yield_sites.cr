require "compiler/crystal/syntax"
require "./scoped"

module Heucristic
  module Syntax
    class YieldSites < Scoped
      record Site, node : Crystal::Yield, context : Context

      getter sites : Array(Site)

      def self.in(
        definition : Crystal::Def,
        enclosing : Array(Index::Identity),
        type_vars : Array(String),
        path : String?,
        version : CrystalVersion::Detected,
      ) : Array(Site)
        finder = new(enclosing, type_vars, definition, path, version)
        definition.body.accept(finder)
        finder.sites
      end

      def initialize(
        enclosing : Array(Index::Identity),
        type_vars : Array(String),
        definition : Crystal::Def,
        path : String?,
        version : CrystalVersion::Detected,
      ) : Nil
        super(enclosing, type_vars, definition, path, version)
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
