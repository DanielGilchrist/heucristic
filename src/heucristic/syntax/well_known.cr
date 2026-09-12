module Heucristic
  module Syntax
    enum WellKnown
      New
      Initialize
      Super
      PreviousDef
      Allocate
      SelfName

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
        end
      end

      def named?(name : String) : Bool
        method_name == name
      end

      def unchecked? : Bool
        case self
        in .super?, .previous_def?, .allocate? then true
        in .new?, .initialize?, .self_name?    then false
        end
      end
    end
  end
end
