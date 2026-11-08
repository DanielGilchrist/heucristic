require "compiler/crystal/syntax"
require "../document/point"
require "./parameter_name"
require "./rescue_name"
require "./scoped"

module Heucristic
  module Syntax
    class Cursor < Scoped
      getter target : Target?
      @lines : Array(String)?

      def self.find(
        tree : Crystal::ASTNode,
        point : Document::Point,
        path : String?,
        version : CrystalVersion::Detected,
        source : String,
      ) : Target?
        cursor = new(point, path, version, source)
        tree.accept(cursor)
        cursor.target
      end

      def initialize(
        @point : Document::Point,
        path : String?,
        version : CrystalVersion::Detected,
        @source : String,
      ) : Nil
        super(path, version)
        @lines = nil
      end

      def visit(node : Crystal::Def) : Bool
        super
        @target = OnDef.new(node, context) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Call) : Bool
        @target = OnCall.new(node, context) if on_name?(node)
        literal_name(node) if @target.nil?
        super
        @target.nil?
      end

      def visit(node : Crystal::Path) : Bool
        if (location = node.location) && over?(location, node.to_s.size)
          @target = OnPath.new(node, context, segment_at(node, location))
        end
        @target.nil?
      end

      def visit(node : Crystal::Var) : Bool
        if over?(node.location, node.name.size)
          @target = OnVar.new(node.name, node.location, context)
        end
        @target.nil?
      end

      def visit(node : Crystal::Rescue) : Bool
        name = node.name
        location = RescueName.location(node, lines)
        @target = OnVar.new(name, location, context) if name && over?(location, name.size)
        @target.nil?
      end

      def visit(node : Crystal::Arg) : Bool
        location = ParameterName.location(node, @source)
        @target = OnVar.new(node.name, location, context) if over?(location, node.name.size + 1)
        @target.nil?
      end

      def visit(node : Crystal::InstanceVar | Crystal::ClassVar) : Bool
        @target = OnInstanceVar.new(node.name, context) if over?(node.location, node.name.size)
        @target.nil?
      end

      def visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Bool
        declared_name(node.name)
        super
        @target.nil?
      end

      def visit(node : Crystal::Alias) : Bool
        declared_name(node.name)
        @target.nil?
      end

      def visit(node : Crystal::Require) : Bool
        statement = "require ".size + node.string.size + 2
        @target = OnRequire.new(node) if over?(node.location, statement)
        false
      end

      def visit(node : Crystal::MacroIf) : Bool
        return false unless @target.nil?

        super
      end

      def visit(node : Crystal::ASTNode) : Bool
        @target.nil?
      end

      protected def expansion_of(
        node : Crystal::MacroIf,
      ) : Index::MacroText::Expansion | Index::MacroText::Undecidable
        Index::MacroText.expand_at(node, @point, @version)
      end

      private def lines : Array(String)
        @lines ||= @source.lines
      end

      private def segment_at(node : Crystal::Path, location : Crystal::Location) : Int32
        offset = @point.column - location.column_number - (node.global? ? 2 : 0)
        node.names.each_with_index do |name, index|
          return index if offset < name.size
          offset -= name.size + 2
        end
        node.names.size - 1
      end

      private def declared_name(name : Crystal::Path) : Nil
        location = name.location
        return unless location && over?(location, name.to_s.size)

        @target = OnPath.new(name, context, segment_at(name, location))
      end

      private def literal_name(node : Crystal::Call) : Nil
        node.args.each do |argument|
          next unless argument.is_a?(Crystal::SymbolLiteral)

          location = argument.location
          next unless location && over?(location, argument.value.size + 1)

          @target = OnName.new(argument.value, location, context)
          return
        end
      end

      private def on_name?(node : Crystal::Call) : Bool
        location = node.name_location
        return over?(location, node.name.size) unless index_sugar?(node)

        over?(location, 1) || closing_bracket(node).try { |point| over?(point, 1) } || false
      end

      private def index_sugar?(node : Crystal::Call) : Bool
        node.name_size.zero? && node.name.starts_with?("[]")
      end

      private def closing_bracket(node : Crystal::Call) : Document::Point?
        finish = node.end_location
        return unless finish

        point = Document::Point.from(finish)
        case node.name
        when "[]"  then point
        when "[]?" then Document::Point.new(point.line, point.column - 1)
        end
      end

      private def over?(location : Crystal::Location?, size : Int32) : Bool
        return false unless location

        over?(Document::Point.from(location), size)
      end

      private def over?(start : Document::Point, size : Int32) : Bool
        @point >= start && @point < start.advance(size)
      end
    end
  end
end
