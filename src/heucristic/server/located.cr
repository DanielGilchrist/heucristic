require "compiler/crystal/syntax"
require "../document/text"
require "../syntax/target"

module Heucristic
  module Server
    record Located,
      uri : String,
      tree : Crystal::ASTNode,
      text : Document::Text,
      path : String,
      target : Syntax::Target
  end
end
