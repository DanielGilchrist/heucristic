require "../syntax/type"
require "./known_exits"
require "./methods"
require "./resolution"

module Heucristic
  module Resolve
    struct CallExits
      include Terminator

      def initialize(
        @methods : Methods,
        @receiver : Resolution,
        @typer : Receiver,
        @context : Syntax::Context,
        @visiting : Array(String),
      ) : Nil
      end

      def terminates?(call : Crystal::Call) : Bool
        return true if call.obj.nil? && KnownExits.new.terminates?(call)
        return no_return_call?(call, @receiver) if call.obj.nil?

        @typer.remembered_exit(call) do
          no_return_call?(call, @typer.of_call(call, @context, Array(Binding).new, @visiting))
        end
      end

      private def no_return_call?(call : Crystal::Call, receiver : Resolution) : Bool
        return false if receiver.is_a?(Unknown)

        shape = Methods::Call.new(
          call.name,
          call.args.size,
          !call.block.nil?,
          Array(Resolution).new,
          Array(String).new,
          Array(Binding).new,
          call.obj.nil?,
        )
        defs = @methods.lookup(receiver, shape)
        !defs.empty? && defs.all? { |entry| @typer.no_return?(entry) }
      end
    end
  end
end
