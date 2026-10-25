module Heucristic
  module Resolve
    struct KnownExits
      NAMES = {"raise", "exit", "abort"}

      def terminates?(call : Crystal::Call) : Bool
        call.obj.nil? && NAMES.includes?(call.name)
      end
    end
  end
end
