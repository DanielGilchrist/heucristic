require "../../spec_helper"

private def read(restriction : String) : Heucristic::Syntax::TypeReader::Outcome
  tree = Heucristic::Syntax.parse("def f(x : #{restriction}); end", "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::Def)

  node = tree.args[0].restriction
  raise "no restriction" unless node

  Heucristic::Syntax::TypeReader.read(node)
end

private def renders(restriction : String, expected : String = restriction) : Nil
  it "reads #{restriction}" do
    read(restriction).to_s.should eq(expected)
  end
end

describe Heucristic::Syntax::TypeReader do
  renders "String"
  renders "::Foo::Bar"
  renders "File?"
  renders "File | Nil"
  renders "Hash(String, Array(Int32)) | Nil"
  renders "Int32*", "::Pointer(Int32)"
  renders "UInt8[4]", "::StaticArray(UInt8, 4)"
  renders "(Int32, String) -> Nil", "Int32, String -> Nil"
  renders "->"
  renders "Int32 -> Nil"
  renders "T.class"
  renders "(A | B).class"
  renders "NamedTuple(x: Int32, y: String?)"
  renders "Tuple(*T)"
  renders "typeof(a)"
  renders "self"
  renders "_"
  renders "(Int32 -> Nil)?"
  renders "Int32 | (String -> Nil)"
  renders "Proc(Int32, Nil)?"
  renders "(A | B)?"

  it "distinguishes the nilable shorthand from an explicit union with Nil" do
    read("File?").should be_a(Heucristic::Syntax::Nilable)
    read("File | Nil").should be_a(Heucristic::Syntax::Union)
  end

  it "compares structurally" do
    read("Hash(String, Int32)?").should eq(read("Hash(String, Int32)?"))
    read("Hash(String, Int32)?").should_not eq(read("Hash(String, Int64)?"))
  end
end

private def mentions_self?(restriction : String) : Bool
  type = read(restriction)
  type.is_a?(Heucristic::Syntax::Type) && Heucristic::Syntax::SelfType.within?(type)
end

describe Heucristic::Syntax::SelfType do
  it "finds self nested anywhere in a restriction" do
    nested = {"self", "Array(self)?", "Hash(String, self.class)", "self -> Int32", "Int32 -> self"}
    nested.each { |text| mentions_self?(text).should be_true }
  end

  it "does not find self inside a type's name" do
    {"Myself", "Array(Itself)", "typeof(x)"}.each { |text| mentions_self?(text).should be_false }
  end
end
