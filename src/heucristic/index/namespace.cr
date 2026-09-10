require "../document/span"
require "./restriction"
require "./class_kind"

module Heucristic
  module Index
    record ClassNamespace,
      name : String,
      path : String,
      name_span : Document::Span,
      kind : ClassKind,
      abstract_type : Bool,
      type_vars : Array(String),
      superclass : Restriction,
      private_path : String? = nil,
      splat_index : Int32? = nil do
      def keyword : String
        kind.struct? ? "struct" : "class"
      end
    end

    record ModuleNamespace,
      name : String,
      path : String,
      name_span : Document::Span,
      type_vars : Array(String),
      private_path : String? = nil do
      def keyword : String
        "module"
      end
    end

    record EnumNamespace,
      name : String,
      path : String,
      name_span : Document::Span,
      base_type : Restriction,
      private_path : String? = nil do
      def keyword : String
        "enum"
      end
    end

    record LibNamespace,
      name : String,
      path : String,
      name_span : Document::Span,
      private_path : String? = nil do
      def keyword : String
        "lib"
      end
    end

    record AnnotationNamespace,
      name : String,
      path : String,
      name_span : Document::Span,
      private_path : String? = nil do
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
