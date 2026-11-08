require "./invalid"

module Score
  record At, text : String, file : String, line : Int32, column : Int32? do
    def self.parse(text : String) : At | Invalid
      invalid = Invalid.new("--at takes <file>:<line>[:<column>], got #{text}")
      parts = text.split(':')
      return invalid unless parts.size.in?(2, 3)

      line = parts[1].to_i32?
      return invalid unless line

      column_text = parts[2]?
      column = column_text.try(&.to_i32?)
      return invalid if column_text && column.nil?

      new(text, parts[0], line, column)
    end

    def covers?(file : String, line : Int32, column : Int32) : Bool
      @file == file && @line == line && (@column.nil? || @column == column)
    end
  end
end
