require "../index/sites"
require "./finding"

module Heucristic
  module Check
    module Inspection
      abstract def run(sites : Index::Sites, findings : Array(Finding)) : Nil
    end
  end
end
