require "../syntax/type"
require "./known_exits"
require "./methods"
require "./resolution"

module Heucristic
  module Resolve
    struct CallExits
      include Terminator

      def initialize(@methods : Methods, @receiver : Resolution) : Nil
      end

      def terminates?(call : Crystal::Call) : Bool
        return false unless call.obj.nil?
        return true if KnownExits.new.terminates?(call)

        receiver = @receiver
        return false if receiver.is_a?(Unknown)

        shape = Methods::Call.new(call.name, call.args.size, !call.block.nil?)
        defs = @methods.lookup(receiver, shape)
        !defs.empty? && defs.all? { |entry| no_return?(entry.return_type) }
      end

      private def no_return?(restriction : Index::Restriction) : Bool
        restriction.is_a?(Syntax::Named) && restriction.names == [CoreType::NoReturn.type_name]
      end
    end
  end
end
