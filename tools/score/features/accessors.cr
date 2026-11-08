require "compiler/crystal/syntax"
require "../../../src/heucristic/document/span"
require "../../../src/heucristic/syntax"

module Score
  module Features
    class Accessors
      NAME = /\A(?:class_)?(?:getter|property|setter)[?!]?\z|\Arecord\z/

      class Collector < Crystal::Visitor
        getter calls : Array(Crystal::Call)

        def initialize : Nil
          @calls = Array(Crystal::Call).new
        end

        def visit(node : Crystal::Call) : Bool
          @calls << node if node.obj.nil? && NAME.matches?(node.name)
          true
        end

        def visit(node : Crystal::ASTNode) : Bool
          true
        end
      end

      def initialize : Nil
        @calls = Hash(String, Array(Crystal::Call)).new
      end

      def declares?(path : String, span : Heucristic::Document::Span) : Bool
        line = span.start_line.to_i + 1
        column = span.start_character.to_i + 1
        calls(path).any? { |call| encloses?(call, line, column) }
      end

      private def calls(path : String) : Array(Crystal::Call)
        @calls[path] ||= collect(path)
      end

      private def collect(path : String) : Array(Crystal::Call)
        return Array(Crystal::Call).new unless File.file?(path)

        tree = Heucristic::Syntax.parse(File.read(path), path)
        return Array(Crystal::Call).new unless tree.is_a?(Crystal::ASTNode)

        collector = Collector.new
        tree.accept(collector)
        collector.calls
      end

      private def encloses?(call : Crystal::Call, line : Int32, column : Int32) : Bool
        first = call.location
        last = call.end_location
        return false unless first && last

        position = {line, column}
        position >= {first.line_number, first.column_number} &&
          position <= {last.line_number, last.column_number}
      end
    end
  end
end
