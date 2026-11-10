require "compiler/crystal/syntax"
require "./no_region"
require "./point"

module Heucristic
  module Document
    record Region, first : Point, last : Point do
      def self.of(node : Crystal::ASTNode) : Region | NoRegion
        first = node.location
        last = node.end_location
        return NoRegion.new unless first && last

        new(Point.from(first), Point.from(last))
      end

      def self.at(line : Int32, first : Int32, last : Int32) : Region
        new(Point.new(line, first), Point.new(line, last))
      end

      def includes?(point : Point) : Bool
        point >= first && point <= last
      end
    end
  end
end
