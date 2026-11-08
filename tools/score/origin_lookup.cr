require "../../src/heucristic/index/entry"
require "../../src/heucristic/index/macro_site"
require "../../src/heucristic/server/macro_lookup"

module Score
  class OriginLookup
    include Heucristic::Server::MacroLookup

    def initialize(@origins : Hash(String, Heucristic::Index::MacroSite)) : Nil
    end

    def site_of(entry : Heucristic::Index::Entry) : Heucristic::Index::MacroSite?
      @origins["#{entry.path}:#{entry.name_span.start_line.to_i + 1}"]?
    end

    def provenance(entry : Heucristic::Index::Entry, root : String) : String?
      site_of(entry).try { |site| "# #{site.provenance(root)}" }
    end

    def hint : String
      ""
    end
  end
end
