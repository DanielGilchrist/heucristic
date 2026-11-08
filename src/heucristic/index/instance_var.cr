require "compiler/crystal/syntax"
require "../document/span"
require "../syntax/type_reader"
require "./origin"
require "./identity"

module Heucristic
  module Index
    record InstanceVar,
      name : String,
      owner : Identity,
      type : Syntax::TypeReader::Outcome,
      path : String,
      name_span : Document::Span,
      origin : Origin,
      expression : Crystal::ASTNode? = nil,
      initialized : Bool = false,
      definition : Crystal::Def? = nil do
      def self.build(
        name : String,
        owner : Identity,
        type : Syntax::TypeReader::Outcome,
        path : String,
        name_span : Document::Span,
        origin : Origin,
        expression : Crystal::ASTNode?,
        initialized : Bool,
        definition : Crystal::Def?,
      ) : InstanceVar
        initialized ||= origin.assigned? && definition.nil?
        new(name, owner, type, path, name_span, origin, expression, initialized, definition)
      end

      def in_def? : Bool
        !definition.nil?
      end
    end
  end
end
