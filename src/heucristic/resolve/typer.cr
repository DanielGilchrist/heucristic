require "compiler/crystal/syntax"
require "./binding"
require "./resolution"
require "./visit"

module Heucristic
  module Resolve
    module Typer
      abstract def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(Visit),
        locals : Array(Binding),
      ) : Resolution
    end
  end
end
