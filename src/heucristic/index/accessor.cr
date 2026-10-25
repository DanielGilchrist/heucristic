require "./receiver"

module Heucristic
  module Index
    enum Accessor
      Getter
      GetterQuery
      GetterBang
      Property
      PropertyQuery
      PropertyBang
      Setter
      ClassGetter
      ClassGetterQuery
      ClassGetterBang
      ClassProperty
      ClassPropertyQuery
      ClassPropertyBang
      ClassSetter

      def self.from_name(name : String) : Accessor?
        each { |accessor| return accessor if accessor.macro_name == name }
        nil
      end

      def self.names : Array(String)
        values.map(&.macro_name)
      end

      def macro_name : String
        case self
        in .getter?               then "getter"
        in .getter_query?         then "getter?"
        in .getter_bang?          then "getter!"
        in .property?             then "property"
        in .property_query?       then "property?"
        in .property_bang?        then "property!"
        in .setter?               then "setter"
        in .class_getter?         then "class_getter"
        in .class_getter_query?   then "class_getter?"
        in .class_getter_bang?    then "class_getter!"
        in .class_property?       then "class_property"
        in .class_property_query? then "class_property?"
        in .class_property_bang?  then "class_property!"
        in .class_setter?         then "class_setter"
        end
      end

      def receiver : Receiver
        case self
        in .getter?, .getter_query?, .getter_bang?, .property?, .property_query?, .property_bang?,
           .setter?
          Receiver::Instance
        in .class_getter?, .class_getter_query?, .class_getter_bang?, .class_property?,
           .class_property_query?, .class_property_bang?, .class_setter?
          Receiver::Metaclass
        end
      end

      def reader_suffix : String
        case self
        in .getter_query?, .property_query?, .class_getter_query?, .class_property_query? then "?"
        in .getter?, .getter_bang?, .property?, .property_bang?, .setter?, .class_getter?,
           .class_getter_bang?, .class_property?, .class_property_bang?, .class_setter?
          ""
        end
      end

      def bang? : Bool
        case self
        in .getter_bang?, .property_bang?, .class_getter_bang?, .class_property_bang?
          true
        in .getter?, .getter_query?, .property?, .property_query?, .setter?, .class_getter?,
           .class_getter_query?, .class_property?, .class_property_query?, .class_setter?
          false
        end
      end

      def reads? : Bool
        !setter? && !class_setter?
      end

      def writes? : Bool
        case self
        in .property?, .property_query?, .property_bang?, .setter?, .class_property?,
           .class_property_query?, .class_property_bang?, .class_setter?
          true
        in .getter?, .getter_query?, .getter_bang?, .class_getter?, .class_getter_query?,
           .class_getter_bang?
          false
        end
      end
    end
  end
end
