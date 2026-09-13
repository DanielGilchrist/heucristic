module Heucristic
  module Syntax
    enum WellKnown
      New
      Initialize
      Super
      PreviousDef
      Allocate
      SelfName
      Dup
      Clone
      Timeout

      def self.from_name(name : String) : WellKnown?
        each { |known| return known if known.method_name == name }
        nil
      end

      def method_name : String
        case self
        in .new?          then "new"
        in .initialize?   then "initialize"
        in .super?        then "super"
        in .previous_def? then "previous_def"
        in .allocate?     then "allocate"
        in .self_name?    then "self"
        in .dup?          then "dup"
        in .clone?        then "clone"
        in .timeout?      then "timeout"
        end
      end

      def named?(name : String) : Bool
        method_name == name
      end

      def unchecked? : Bool
        case self
        in .super?, .previous_def?, .allocate?                         then true
        in .new?, .initialize?, .self_name?, .dup?, .clone?, .timeout? then false
        end
      end

      def copies? : Bool
        case self
        in .dup?, .clone? then true
        in .new?, .initialize?, .self_name?, .super?, .previous_def?, .allocate?, .timeout?
          false
        end
      end
    end
  end
end
