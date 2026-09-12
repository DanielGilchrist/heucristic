require "compiler/crystal/syntax"
require "../document/text"
require "../syntax/uses"

module Heucristic
  module Index
    record Sites,
      path : String,
      text : Document::Text,
      tree : Crystal::ASTNode,
      calls : Array(Syntax::Uses::CallSite),
      paths : Array(Syntax::Uses::PathSite),
      cases : Array(Syntax::Uses::CaseSite),
      generics : Array(Syntax::Uses::GenericSite),
      controls : Array(Syntax::Uses::ControlSite),
      defs : Array(Syntax::Uses::DefSite),
      instance_vars : Array(Syntax::Uses::InstanceVarSite) do
      def self.of(path : String, text : Document::Text, tree : Crystal::ASTNode) : Sites
        uses = Syntax::Uses.in(tree, path)
        new(
          path, text, tree, uses.calls, uses.paths, uses.cases, uses.generics, uses.controls,
          uses.def_sites, uses.instance_vars,
        )
      end
    end
  end
end
