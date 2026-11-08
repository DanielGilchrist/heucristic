require "./resolution"
require "../index/identity"
require "../index/owner"
require "../index/receiver"

module Heucristic
  module Resolve
    record VariableVisit, name : String, owner : UInt64? do
      def cycle : Unknown
        Unknown.new(:cycle, name)
      end
    end

    record DefVisit, owner : Index::Owner, receiver : Index::Receiver, name : String do
      def self.of(entry : Index::Def) : DefVisit
        new(entry.owner, entry.receiver, entry.name)
      end

      def cycle : Unknown
        Unknown.new(:cycle, label)
      end

      private def label : String
        case (current = owner)
        in Index::TopLevel then name
        in Index::Identity then "#{current}#{receiver.metaclass? ? "." : "#"}#{name}"
        end
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

    record ConstantVisit, identity : Index::Identity do
      def cycle : Unknown
        Unknown.new(:cycle, identity.name)
      end
    end

    record InstanceVarVisit, name : String

    record IncluderVisit, owner : Index::Identity

    alias Visit = VariableVisit | DefVisit | ExpansionVisit | DispatchVisit |
                  ConstantVisit | InstanceVarVisit | IncluderVisit
  end
end
