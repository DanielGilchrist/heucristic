require "../../src/heucristic/index/def"
require "../../src/heucristic/resolve/receiver"
require "../../src/heucristic/syntax/context"

module Score
  record CallTargets, receiver : Heucristic::Resolve::Receiver do
    def of(
      call : Crystal::Call,
      context : Heucristic::Syntax::Context,
    ) : Array(Heucristic::Index::Def)
      typed = @receiver.of_call(call, context)
      return Array(Heucristic::Index::Def).new if typed.is_a?(Heucristic::Resolve::Unknown)

      if call.obj.nil? && Heucristic::Syntax::WellKnown::Super.named?(call.name)
        @receiver.super_targets(call, context)
      else
        @receiver.implementations(typed, @receiver.shape_of(call, context))
      end
    end
  end
end
