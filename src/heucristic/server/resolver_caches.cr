require "../resolve/types"
require "../resolve/methods"
require "../resolve/receiver"

module Heucristic
  module Server
    class ResolverCaches
      def initialize(
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
      ) : Nil
      end

      def invalidate : Nil
        @types.invalidate
        @methods.invalidate
        @receiver.invalidate
      end
    end
  end
end
