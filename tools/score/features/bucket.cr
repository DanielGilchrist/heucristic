require "./place"

module Score
  module Features
    class Bucket
      EXAMPLES = 2

      record Example, place : Place, detail : String

      getter count = 0
      getter examples = Array(Example).new(EXAMPLES)

      def add(place : Place, detail : String) : Nil
        @count += 1
        @examples << Example.new(place, detail) if @examples.size < EXAMPLES
      end
    end
  end
end
