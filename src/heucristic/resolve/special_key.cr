require "../index/owner"
require "../index/receiver"

module Heucristic
  module Resolve
    record SpecialKey, owner : Index::Owner, receiver : Index::Receiver, name : String do
      def self.new(owner : String, receiver : Index::Receiver, name : String) : SpecialKey
        new(Index::Public.new(owner), receiver, name)
      end
    end
  end
end
