require "../../spec_helper"

private MACRO_UNKNOWN = "unknown (macro: `key` is a macro; its expansion is not typed)"

describe Heucristic::Resolve::MacroPrecedence do
  it "types a call to a macro in an included module over a def in the superclass" do
    source = <<-CR
      module Keys
        macro key(name)
          {{name}}
        end
      end

      class Parent
        def key(name : String) : String
          name
        end
      end

      class Child < Parent
        include Keys

        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call to a top-level macro over a top-level def" do
    source = <<-CR
      macro key(name)
        {{name}}
      end

      def key(name) : String
        name
      end

      key(1).size
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call to a top-level macro over a top-level def from inside a class" do
    source = <<-CR
      macro key(name)
        {{name}}
      end

      def key(name) : String
        name
      end

      class Holder
        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call to a macro with defaults, a splat and a double splat over a class def" do
    source = <<-CR
      class Keyed
        macro key(first, second = 2, *rest, **options)
          {{first}}
        end

        def self.key(name) : String
          name
        end

        def self.run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call to a macro in a subclass over a class def in the superclass" do
    source = <<-CR
      class Parent
        def self.key(name : String) : String
          name
        end
      end

      class Child < Parent
        macro key(name)
          {{name}}
        end

        def self.run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call to a class macro over an instance def of the same class" do
    source = <<-CR
      class Keyed
        macro key(name)
          {{name}}
        end

        def key(name : String) : String
          name
        end

        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "types a call through the def of a class that extends the module declaring the macro" do
    source = <<-CR
      module Keys
        macro key(name)
          {{name}}
        end
      end

      class Keyed
        extend Keys

        def self.key(first : String, second : String) : String
          first
        end

        def self.run : Nil
          key("a", "b").size
        end
      end
      CR
    receiver_of_size(source, "key(\"a\", \"b\").size").should eq("String")
  end

  it "types a call through a def in a subclass that shadows the superclass macro" do
    source = <<-CR
      class Parent
        macro key(name)
          {{name}}
        end
      end

      class Child < Parent
        def self.key(name : String, count : Int32 = 1) : String
          name
        end

        def self.run : Nil
          key("x").size
        end
      end
      CR
    receiver_of_size(source, "key(\"x\").size").should eq("String")
  end

  it "keeps a def that does not fit the call from resolving to the superclass macro's type" do
    source = <<-CR
      class Parent
        macro key(name)
          {{name}}
        end
      end

      class Child < Parent
        def key(first : String, second : String) : String
          first
        end

        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should start_with("unknown (")
  end

  it "types a call through the def when the macro's arity does not fit" do
    source = <<-CR
      class Keyed
        macro key(first, second)
          {{first}}
        end

        def self.key(name : String) : String
          name
        end

        def self.run : Nil
          key("x").size
        end
      end
      CR
    receiver_of_size(source, "key(\"x\").size").should eq("String")
  end

  it "does not decide between a macro and a def when a splat argument hides the arity" do
    source = <<-CR
      class Keyed
        macro key(name)
          {{name}}
        end

        def self.key(name : String) : String
          name
        end

        def self.run(names : Array(Int32)) : Nil
          key(*names).size
        end
      end
      CR
    receiver_of_size(source, "key(*names).size").should eq(
      "unknown (macro: `key` is a macro or a def depending on arguments not known here)"
    )
  end

  it "lets a macro in the module included last win over an earlier def" do
    source = <<-CR
      module Defs
        def key(name : Int32) : String
          "d"
        end
      end

      module Macros
        macro key(name)
          {{name}}
        end
      end

      class Host
        include Defs
        include Macros

        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq(MACRO_UNKNOWN)
  end

  it "lets the def of the module included last win over an earlier macro" do
    source = <<-CR
      module Macros
        macro key(name)
          {{name}}
        end
      end

      module Defs
        def key(name : Int32) : String
          "d"
        end
      end

      class Host
        include Macros
        include Defs

        def run : Nil
          key(1).size
        end
      end
      CR
    receiver_of_size(source, "key(1).size").should eq("String")
  end
end
