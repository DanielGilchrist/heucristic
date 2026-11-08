require "../index/owner"
require "../index/receiver"

module Heucristic
  module Resolve
    record SpecialKey, owner : Index::Owner, receiver : Index::Receiver, name : String
  end
end
