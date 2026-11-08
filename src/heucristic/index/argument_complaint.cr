module Heucristic
  module Index
    record AlreadySpecified, name : String do
      def to_s(io : IO) : Nil
        io << "argument for parameter '" << name << "' already specified"
      end
    end

    record NoParameter, name : String do
      def to_s(io : IO) : Nil
        io << "no parameter named '" << name << '\''
      end
    end

    record MissingArgument, name : String do
      def to_s(io : IO) : Nil
        io << "missing argument: " << name
      end
    end

    alias ArgumentComplaint = AlreadySpecified | NoParameter | MissingArgument
  end
end
