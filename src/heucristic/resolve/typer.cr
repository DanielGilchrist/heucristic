require "compiler/crystal/syntax"
require "./frame"
require "./resolution"

module Heucristic
  module Resolve
    module Typer
      abstract def type_of(node : Crystal::ASTNode, frame : Frame) : Resolution
    end
  end
end
