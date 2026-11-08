require "./resolution"

module Heucristic
  module Resolve
    record VariableVisit, name : String, owner : UInt64? do
      def cycle : Unknown
        Unknown.new(:cycle, name)
      end
    end

    record DefVisit, qualified : String do
      def cycle : Unknown
        Unknown.new(:cycle, qualified)
      end
    end

    record ExpansionVisit, path : String, line : Int32, column : Int32, name : String do
      def cycle : Unknown
        Unknown.new(:cycle, name)
      end
    end

    record DispatchVisit, receiver : TypeRef, name : String, arity : Int32 do
      def cycle : Unknown
        Unknown.new(:cycle, "#{receiver}##{name}/#{arity}")
      end
    end

    record ConstantVisit, name : String do
      def cycle : Unknown
        Unknown.new(:cycle, name)
      end
    end

    record InstanceVarVisit, name : String

    record IncluderVisit, owner : String

    alias Visit = VariableVisit | DefVisit | ExpansionVisit | DispatchVisit |
                  ConstantVisit | InstanceVarVisit | IncluderVisit
  end
end
