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
      cases : Array(Syntax::Uses::CaseSite) do
      def self.of(path : String, text : Document::Text, tree : Crystal::ASTNode) : Sites
        uses = Syntax::Uses.in(tree, path)
        new(path, text, tree, uses.calls, uses.paths, uses.cases)
      end
    end
  end
end
