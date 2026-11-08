require "../index/entry"
require "../index/macro_site"

module Heucristic
  module Server
    module MacroLookup
      abstract def site_of(entry : Index::Entry) : Index::MacroSite?
      abstract def provenance(entry : Index::Entry, root : String) : String?
      abstract def hint : String
    end
  end
end
