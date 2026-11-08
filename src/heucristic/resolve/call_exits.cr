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
        @visiting : Array(Visit),
      ) : Nil
      end

      def terminates?(call : Crystal::Call, path : Array(Crystal::ASTNode)) : Bool
        return true if call.obj.nil? && KnownExits.new.terminates?(call)
        return no_return_call?(call, @receiver) if call.obj.nil?

        @typer.remembered_exit(call, @context.at(path), @visiting) do |receiver|
          no_return_call?(call, receiver)
        end
      end

      private def no_return_call?(call : Crystal::Call, receiver : Resolution) : Bool
        return false if receiver.is_a?(Unknown)

        shape = Methods::CallShape.new(
          call.name,
          call.args.size,
          !call.block.nil?,
          implicit: call.obj.nil?,
        )
        defs = @methods.lookup(receiver, shape)
        !defs.empty? && defs.all? { |entry| @typer.no_return?(entry) }
      end
    end
  end
end
