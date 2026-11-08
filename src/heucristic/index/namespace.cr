require "../document/span"
require "./restriction"
require "./identity"
require "./class_kind"

module Heucristic
  module Index
    record ClassNamespace,
      identity : Identity,
      path : String,
      name_span : Document::Span,
      kind : ClassKind,
      abstract_type : Bool,
      type_vars : Array(String),
      superclass : Restriction,
      splat_index : Int32? = nil do
      delegate name, to: identity

      def keyword : String
        kind.struct? ? "struct" : "class"
      end
    end

    record ModuleNamespace,
      identity : Identity,
      path : String,
      name_span : Document::Span,
      type_vars : Array(String) do
      delegate name, to: identity

      def keyword : String
        "module"
      end
    end

    record EnumNamespace,
      identity : Identity,
      path : String,
      name_span : Document::Span,
      base_type : Restriction,
      flags : Bool = false do
      delegate name, to: identity

      def keyword : String
        "enum"
      end
    end

    record LibNamespace,
      identity : Identity,
      path : String,
      name_span : Document::Span do
      delegate name, to: identity

      def keyword : String
        "lib"
      end
    end

    record AnnotationNamespace,
      identity : Identity,
      path : String,
      name_span : Document::Span do
      delegate name, to: identity

      def keyword : String
        "annotation"
      end
    end

    alias Namespace = ClassNamespace |
                      ModuleNamespace |
                      EnumNamespace |
                      LibNamespace |
                      AnnotationNamespace
  end
end
