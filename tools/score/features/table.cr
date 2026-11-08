require "./kind"
require "./row"

module Score
  module Features
    class Table
      getter rows = Hash(Kind, Row).new

      def add(observation : Observation) : Nil
        @rows[observation.site.kind] ||= Row.new
        @rows[observation.site.kind].add(observation)
      end

      def total : Int32
        @rows.each_value.sum(&.total)
      end

      def defects : Int32
        @rows.each_value.sum { |row| row.empties.size + row.crashes.size }
      end
    end
  end
end
