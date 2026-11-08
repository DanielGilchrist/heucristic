require "../index/workspace"
require "../resolve/types"
require "../resolve/methods"
require "../resolve/receiver"
require "./settled"
require "./fit"

module Heucristic
  module Check
    struct Environment
      getter workspace : Index::Workspace
      getter types : Resolve::Types
      getter methods : Resolve::Methods
      getter receiver : Resolve::Receiver
      getter settled : Settled
      getter root : String
      getter fit : Fit

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @settled : Settled,
        @root : String,
      ) : Nil
        @fit = Fit.new(@methods)
      end
    end
  end
end
