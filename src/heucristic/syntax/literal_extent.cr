require "compiler/crystal/syntax"
require "../document/no_region"
require "../document/point"
require "../document/region"

module Heucristic
  module Syntax
    record LiteralExtent, regions : Array(Document::Region) do
      HEREDOC_OPENER = /\A<<[-~]?(?:"[^"]*"|'[^']*'|\w+)/
      OPENER         = /[\[{(]/

      def self.whole(
        node : Crystal::StringLiteral | Crystal::StringInterpolation | Crystal::CharLiteral |
               Crystal::BoolLiteral | Crystal::NilLiteral | Crystal::RegexLiteral |
               Crystal::NumberLiteral | Crystal::SymbolLiteral,
        lines : Array(String),
      ) : LiteralExtent | Document::NoRegion
        region = Document::Region.of(node)
        return region if region.is_a?(Document::NoRegion)

        case node
        in Crystal::StringLiteral, Crystal::StringInterpolation
          heredoc(region, lines)
        in Crystal::CharLiteral, Crystal::BoolLiteral, Crystal::NilLiteral, Crystal::RegexLiteral,
           Crystal::NumberLiteral, Crystal::SymbolLiteral
          new([region])
        end
      end

      def self.delimiters(
        node : Crystal::ArrayLiteral | Crystal::HashLiteral | Crystal::TupleLiteral |
               Crystal::NamedTupleLiteral | Crystal::RangeLiteral | Crystal::ProcLiteral,
        lines : Array(String),
      ) : LiteralExtent | Document::NoRegion
        case node
        in Crystal::ArrayLiteral
          bracketed(node, node.name, node.of.try(&.location), lines)
        in Crystal::HashLiteral
          bracketed(node, node.name, node.of.try(&.key.location), lines)
        in Crystal::TupleLiteral, Crystal::NamedTupleLiteral
          bracketed(node, nil, nil, lines)
        in Crystal::RangeLiteral then operator(node, lines)
        in Crystal::ProcLiteral  then arrow(node, lines)
        end
      end

      def includes?(point : Document::Point) : Bool
        regions.any?(&.includes?(point))
      end

      private def self.heredoc(whole : Document::Region, lines : Array(String)) : LiteralExtent
        return new([whole]) unless whole.first.line < whole.last.line

        written = lines[whole.first.line - 1]?.try(&.[(whole.first.column - 1)..]?)
        opener = written.try { |text| HEREDOC_OPENER.match(text) }
        return new([whole]) unless opener

        token = Document::Region.at(
          whole.first.line, whole.first.column, whole.first.column + opener[0].size - 1
        )
        body = Document::Region.new(Document::Point.new(whole.first.line + 1, 1), whole.last)
        new([token, body])
      end

      private def self.bracketed(
        node : Crystal::ASTNode,
        name : Crystal::ASTNode?,
        element_type : Crystal::Location?,
        lines : Array(String),
      ) : LiteralExtent | Document::NoRegion
        whole = Document::Region.of(node)
        return whole if whole.is_a?(Document::NoRegion)

        name_end = name.try(&.end_location)
        from = name_end ? Document::Point.from(name_end).advance(1) : whole.first
        regions = [opening(from, lines)]
        if element_type
          regions.concat(before_of(Document::Point.from(element_type), lines))
        else
          regions << Document::Region.new(whole.last, whole.last)
        end
        new(regions)
      end

      private def self.opening(first : Document::Point, lines : Array(String)) : Document::Region
        line = lines[first.line - 1]?
        index = line.try(&.index(OPENER, first.column - 1))
        return Document::Region.new(first, first) unless line && index

        Document::Region.at(first.line, first.column, index + 1)
      end

      private def self.before_of(
        type_start : Document::Point,
        lines : Array(String),
      ) : Array(Document::Region)
        line = lines[type_start.line - 1]?
        return Array(Document::Region).new unless line

        keyword_end = skip_back(line, type_start.column - 2)
        keyword_start = keyword_end - 1
        unless keyword_start >= 0 && line[keyword_start..keyword_end]? == "of"
          return Array(Document::Region).new
        end

        closing = skip_back(line, keyword_start - 1)
        return Array(Document::Region).new if closing < 0

        [
          Document::Region.at(type_start.line, closing + 1, closing + 1),
          Document::Region.at(type_start.line, keyword_start + 1, keyword_end + 1),
        ]
      end

      private def self.skip_back(line : String, index : Int32) : Int32
        while index >= 0 && line[index].whitespace?
          index -= 1
        end
        index
      end

      private def self.operator(
        node : Crystal::RangeLiteral,
        lines : Array(String),
      ) : LiteralExtent | Document::NoRegion
        whole = Document::Region.of(node)
        return whole if whole.is_a?(Document::NoRegion)

        after = node.from.end_location
        start = after ? Document::Point.from(after).advance(1) : whole.first
        line = lines[start.line - 1]?
        return Document::NoRegion.new unless line

        column = start.column
        while line[column - 1]?.try(&.whitespace?)
          column += 1
        end
        operator = node.exclusive? ? "..." : ".."
        return Document::NoRegion.new unless line[(column - 1), operator.size]? == operator

        new([Document::Region.at(start.line, column, column + operator.size - 1)])
      end

      private def self.arrow(
        node : Crystal::ProcLiteral,
        lines : Array(String),
      ) : LiteralExtent | Document::NoRegion
        first = node.location
        return Document::NoRegion.new unless first

        written = lines[first.line_number - 1]?.try(&.[(first.column_number - 1), 2]?)
        return Document::NoRegion.new unless written == "->"

        new([Document::Region.at(first.line_number, first.column_number, first.column_number + 1)])
      end
    end
  end
end
