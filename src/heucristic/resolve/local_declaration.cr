require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    record LocalDeclaration, declared_type : Crystal::ASTNode, location : Crystal::Location?
  end
end
