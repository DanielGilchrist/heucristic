module Heucristic
  module Resolve
    module Builtins
      record NoSuperclass
      record Generic, name : String, type_vars : Array(String), splat_index : Int32?

      GENERICS = [
        Generic.new("Tuple", ["T"], 0),
        Generic.new("NamedTuple", ["T"], 0),
        Generic.new("Proc", ["T", "R"], 0),
        Generic.new("Union", ["T"], 0),
        Generic.new("Pointer", ["T"], nil),
        Generic.new("StaticArray", ["T", "N"], nil),
      ]

      ROOTS = {"Object", "NoReturn", "Void", "Enumerable", "Indexable", "Crystal"}

      SUPERCLASSES = {
        {"Reference", "Object"}, {"Value", "Object"}, {"Number", "Value"}, {"Nil", "Value"},
        {"Bool", "Value"}, {"Char", "Value"}, {"Int", "Number"}, {"Int8", "Int"}, {"UInt8", "Int"},
        {"Int16", "Int"}, {"UInt16", "Int"}, {"Int32", "Int"}, {"UInt32", "Int"}, {"Int64", "Int"},
        {"UInt64", "Int"}, {"Int128", "Int"}, {"UInt128", "Int"}, {"Float", "Number"},
        {"Float32", "Float"}, {"Float64", "Float"}, {"Symbol", "Value"}, {"Pointer", "Value"},
        {"Tuple", "Value"}, {"NamedTuple", "Value"}, {"StaticArray", "Value"},
        {"String", "Reference"}, {"Class", "Value"}, {"Struct", "Value"}, {"Array", "Reference"},
        {"Hash", "Reference"}, {"Regex", "Reference"}, {"Range", "Struct"}, {"Slice", "Struct"},
        {"Exception", "Reference"}, {"Enum", "Value"}, {"Proc", "Value"}, {"Union", "Value"},
      }

      CONSTANTS = {
        "Crystal::BUILD_COMMIT", "Crystal::BUILD_DATE", "Crystal::CACHE_DIR",
        "Crystal::DEFAULT_PATH", "Crystal::DESCRIPTION", "Crystal::PATH", "Crystal::VERSION",
        "Crystal::LLVM_VERSION", "Crystal::HOST_TRIPLE", "Crystal::TARGET_TRIPLE",
        "Crystal::LIBRARY_PATH", "Crystal::LIBRARY_RPATH",
      }

      def self.includes?(name : String) : Bool
        ROOTS.includes?(name) || SUPERCLASSES.any? { |entry| entry[0] == name }
      end

      def self.constant?(name : String) : Bool
        CONSTANTS.includes?(name)
      end

      def self.type_vars(name : String) : Array(String)
        GENERICS.find(&.name.==(name)).try(&.type_vars) || Array(String).new
      end

      def self.splat_index(name : String) : Int32?
        GENERICS.find(&.name.==(name)).try(&.splat_index)
      end

      def self.superclass(name : String) : String | NoSuperclass
        entry = SUPERCLASSES.find { |candidate| candidate[0] == name }
        entry ? entry[1] : NoSuperclass.new
      end
    end
  end
end
