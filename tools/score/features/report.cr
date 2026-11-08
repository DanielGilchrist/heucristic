require "../corpus"
require "./table"

module Score
  module Features
    class Report
      REASONS_PER_KIND =  5
      LISTED           = 25

      def initialize(@corpus : Corpus, @table : Table) : Nil
      end

      def print(files : Int32, elapsed : Time::Span) : Nil
        puts "#{@table.total} positions in #{files} files under #{@corpus.root} answered in " \
             "#{elapsed.total_milliseconds.round}ms"
        puts
        table
        reasons
        defects
        untargeted
        without_definition
      end

      private def table : Nil
        puts "#{"kind".ljust(26)} #{"total".rjust(6)} #{"answered".rjust(9)} " \
             "#{"unknown".rjust(8)} #{"empty".rjust(6)} #{"crash".rjust(6)} #{"no def".rjust(7)}"
        each_row do |kind, row|
          puts "#{kind.label.ljust(26)} #{row.total.to_s.rjust(6)} " \
               "#{percent(row.answered, row.total).rjust(9)} " \
               "#{percent(row.unanswered, row.total).rjust(8)} " \
               "#{row.empties.size.to_s.rjust(6)} #{row.crashes.size.to_s.rjust(6)} " \
               "#{row.without_definition.size.to_s.rjust(7)}"
        end
      end

      private def reasons : Nil
        each_row do |kind, row|
          next if row.reasons.empty?

          puts
          puts "unknown: #{kind.label}"
          ranked = row.reasons.to_a.sort_by { |reason, bucket| {-bucket.count, reason} }
          ranked.first(REASONS_PER_KIND).each do |reason, bucket|
            puts "  #{bucket.count.to_s.rjust(6)}x #{reason}"
            bucket.examples.each do |example|
              puts "          e.g. #{where(example.place)}  #{example.detail}"
            end
          end
        end
      end

      private def defects : Nil
        puts
        puts "EMPTY hovers (a bug): #{@table.rows.each_value.sum(&.empties.size)}"
        each_row do |kind, row|
          row.empties.each { |place| puts "  #{kind.label}: #{where(place)}" }
        end
        puts "CRASHES (a bug): #{@table.rows.each_value.sum(&.crashes.size)}"
        each_row do |kind, row|
          row.crashes.each do |crash|
            puts "  #{kind.label}: #{where(crash.place)} #{crash.message}"
          end
        end
      end

      private def untargeted : Nil
        puts "NO TARGET (the cursor finds nothing at a hoverable position): " \
             "#{@table.rows.each_value.sum(&.untargeted.size)}"
        each_row do |kind, row|
          next if row.untargeted.empty?

          puts "  #{kind.label} (#{row.untargeted.size})"
          row.untargeted.first(LISTED).each { |place| puts "    #{where(place)}" }
          rest = row.untargeted.size - LISTED
          puts "    ... #{rest} more" if rest > 0
        end
      end

      private def without_definition : Nil
        puts "answered hover with null definition: " \
             "#{@table.rows.each_value.sum(&.without_definition.size)}"
        each_row do |kind, row|
          listed = row.without_definition
          next if listed.empty?

          puts "  #{kind.label} (#{listed.size})"
          listed.first(LISTED).each do |unlocated|
            puts "    #{where(unlocated.place)} via #{unlocated.via}"
          end
          rest = listed.size - LISTED
          puts "    ... #{rest} more" if rest > 0
        end
      end

      private def each_row(& : Kind, Row ->) : Nil
        Kind.each do |kind|
          row = @table.rows[kind]?
          yield kind, row if row
        end
      end

      private def where(place : Place) : String
        "#{@corpus.relative(place.path)}:#{place.line}:#{place.column}"
      end

      private def percent(part : Int32, whole : Int32) : String
        return "0.0%" if whole.zero?

        "#{(part * 1000 // whole / 10.0).round(1)}%"
      end
    end
  end
end
