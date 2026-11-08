require "./kind"

module Score
  module Features
    record Site, kind : Kind, line : Int32, column : Int32, name : String
  end
end
