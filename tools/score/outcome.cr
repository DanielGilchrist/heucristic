require "../../src/heucristic/resolve/receiver"
require "../../src/heucristic/index/def"

module Score
  record Outcome,
    path : String,
    line : Int32,
    column : Int32,
    name : String,
    result : Heucristic::Resolve::Resolution,
    targets : Array(Heucristic::Index::Def),
    interpolated : Bool do
    def location : String
      "#{path}:#{line}:#{column}"
    end
  end
end
