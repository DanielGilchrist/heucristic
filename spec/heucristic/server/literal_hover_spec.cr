require "../../spec_helper"

private record Marked, source : String, line : Int32, character : Int32

private def marked(text : String) : Marked
  offset = text.index('‸')
  raise "no marker in #{text.inspect}" unless offset

  before = text[0, offset]
  line = before.count('\n')
  character = offset - (before.rindex('\n').try(&.+(1)) || 0)
  Marked.new(text.delete('‸'), line, character)
end

private def hover_at(text : String) : String?
  position = marked(text)
  text = nil
  with_document(position.source) do |client|
    text = hover_text(client.hover(DOCUMENT_URI, position.line, position.character))
  end
  text
end

private def typed(name : String) : String
  "```crystal\n#{name}\n```"
end

HELPERS = <<-CR
  def label : String
    "x"
  end

  def mystery
    rand
  end

  CR

describe "hover on literals" do
  it "types an Int32 literal as crystal does with typeof" do
    hover_at("x = ‸1\n").should eq(typed("Int32"))
  end

  it "types a literal with an i64 suffix as Int64" do
    hover_at("x = 1_‸i64\n").should eq(typed("Int64"))
  end

  it "types a float literal as Float64" do
    hover_at("x = 1‸.5\n").should eq(typed("Float64"))
  end

  it "types an interpolated string as String and keeps the interpolated variable" do
    hover_at("def f(user_id : Int32)\n  \"/lea‸ve/\#{user_id}\"\nend\n").should eq(typed("String"))
    inside = hover_at("def f(user_id : Int32)\n  \"/leave/\#{user‸_id}\"\nend\n")
    inside.to_s.should contain("Int32")
  end

  it "types an array of strings" do
    hover_at("x = ‸[\".a\", \".b\"]\n").should eq(typed("Array(String)"))
    hover_at("x = [\".‸a\", \".b\"]\n").should eq(typed("String"))
  end

  it "types a hash whose values are resolving calls and keeps the call under the cursor" do
    hover_at(HELPERS + "x = ‸{\"a\" => label, \"b\" => label}\n").should eq(
      typed("Hash(String, String)")
    )
    hover_at(HELPERS + "x = {\"a\" => la‸bel, \"b\" => label}\n").to_s.should contain("def label")
  end

  it "reports the unknown reason for a hash whose value cannot be typed" do
    text = hover_at(HELPERS + "x = ‸{\"a\" => mystery}\n").to_s
    text.should start_with("unknown (")
    text.should_not contain("Object")
  end

  it "types a tuple as crystal does with typeof" do
    hover_at("x = ‸{1, \"a\"}\n").should eq(typed("Tuple(Int32, String)"))
  end

  it "types a named tuple as crystal does with typeof" do
    hover_at("x = ‸{a: 1, b: \"s\"}\n").should eq(typed("NamedTuple(a: Int32, b: String)"))
  end

  it "gives a short single-line reason for a proc whose type is not written" do
    text = hover_at("x = -‸> do\n  1\nend\n").to_s
    text.should start_with("unknown (inference needed: ")
    text.lines.size.should eq(1)
  end

  it "replies null on blank space and on punctuation outside any literal" do
    with_document("x = [1]   \n\ny = 2\n") do |client|
      client.hover(DOCUMENT_URI, 0, 9).result.try(&.raw).should be_nil
      client.hover(DOCUMENT_URI, 1, 0).result.try(&.raw).should be_nil
      client.hover(DOCUMENT_URI, 0, 2).result.try(&.raw).should be_nil
      client.definition(DOCUMENT_URI, 0, 9).result.try(&.raw).should be_nil
    end
  end

  it "replies null on whitespace inside a multi-line container" do
    hover_at("x = [\n  ‸ 1,\n  2,\n]\n").should be_nil
    hover_at("x = {\n  \"a\" =>‸ 1,\n}\n").should be_nil
  end

  it "replies null inside a macro expression" do
    hover_at("def f\n  {{ [1, ‸2].size }}\nend\n").should be_nil
  end

  it "replies null on a number in a static array type" do
    hover_at("def f(a : StaticArray(Int32, ‸3))\nend\n").should be_nil
  end

  it "gives no definition, references or rename for a literal" do
    with_document("x = 1\ny = x\n") do |client|
      client.definition(DOCUMENT_URI, 0, 4).result.try(&.raw).should be_nil
      client.references(DOCUMENT_URI, 0, 4).result.try(&.raw).should be_nil
      client.rename(DOCUMENT_URI, 0, 4, "z").result.try(&.raw).should be_nil
    end
  end

  it "types a literal argument of an annotation as itself" do
    hover_at("@[Foo(‸1)]\nclass A\nend\n").should eq(typed("Int32"))
    hover_at("@[Foo(bar: ‸1)]\nclass A\nend\n").should eq(typed("Int32"))
  end
end

describe "hover on literals that take the type of where they land" do
  it "takes the declared type of a type declaration (crystal: Int64)" do
    hover_at("x : Int64 = ‸1\n").should eq(typed("Int64"))
  end

  it "takes the declared type of a union member (crystal: typeof is Int64)" do
    hover_at("x : Int64 | String = ‸3\n").should eq(typed("Int64"))
  end

  it "takes the element type of an array literal with `of` (crystal: Array(Int64))" do
    hover_at("x = [‸1, 2] of Int64\n").should eq(typed("Int64"))
  end

  it "takes the key and value types of a hash literal with `of` (crystal: Hash(Int64, Int8))" do
    hover_at("x = {‸1 => 2} of Int64 => Int8\n").should eq(typed("Int64"))
    hover_at("x = {1 => ‸2} of Int64 => Int8\n").should eq(typed("Int8"))
  end

  it "takes the restriction of a parameter's default value (crystal: Int8)" do
    hover_at("def g(z : Int8 = ‸1)\n  z\nend\n").should eq(typed("Int8"))
  end

  it "keeps its own type for a default value without a restriction (crystal: Int32)" do
    hover_at("def g(z = ‸1)\n  z\nend\n").should eq(typed("Int32"))
  end

  it "takes the enum's base type for a member value (crystal: UInt8)" do
    hover_at("enum Color : UInt8\n  Red = ‸1\nend\n").should eq(typed("UInt8"))
  end

  it "keeps Int32 for a member value of an enum without a base type (crystal: Int32)" do
    hover_at("enum Color\n  Red = ‸1\nend\n").should eq(typed("Int32"))
  end

  it "takes the enum for a symbol default value (crystal: Color)" do
    hover_at("enum Color\n  Red\nend\n\ndef g(c : Color = :‸red)\n  c\nend\n").should eq(
      typed("Color")
    )
  end

  it "takes the declared type of an instance variable it is assigned to (crystal: Int64)" do
    source = "class K\n  @x : Int64\n\n  def initialize\n    @x = ‸1\n  end\nend\n"
    hover_at(source).should eq(typed("Int64"))
  end

  it "keeps its own type for an instance variable that is not declared (crystal: Int32)" do
    hover_at("class K\n  def initialize\n    @x = ‸1\n  end\nend\n").should eq(typed("Int32"))
  end

  it "takes the parameter type when only that overload needs the autocast (crystal: Int64)" do
    hover_at("def f(x : Int64)\n  x\nend\n\nf(‸1)\n").should eq(typed("Int64"))
  end

  it "takes the parameter type of a float literal (crystal: Float32)" do
    hover_at("def q(a : Float32)\n  a\nend\n\nq(‸1.5)\n").should eq(typed("Float32"))
  end

  it "takes the enum for a positional symbol argument (crystal: Color)" do
    hover_at("enum Color\n  Red\nend\n\ndef fcol(c : Color)\n  c\nend\n\nfcol(:‸red)\n").should eq(
      typed("Color")
    )
  end

  it "takes the enum for a named symbol argument (crystal: Color)" do
    hover_at(
      "enum Color\n  Red\nend\n\ndef kw(color : Color)\n  color\nend\n\nkw(color: :‸red)\n"
    ).should eq(typed("Color"))
  end

  it "keeps its own type when an overload accepts it without conversion (crystal picks Int32)" do
    source = "def over(x : Int32)\nend\n\ndef over(x : Int64)\nend\n\nover(‸1)\n"
    hover_at(source).should eq(typed("Int32"))
  end

  it "does not guess when several overloads need the conversion (crystal: ambiguous call)" do
    source = "def amb(x : Int16)\nend\n\ndef amb(x : Int64)\nend\n\namb(‸1)\n"
    text = hover_at(source).to_s
    text.should start_with("unknown (ambiguous: ")
    text.should contain("Int16")
    text.should contain("Int64")
  end

  it "does not guess when the call does not resolve" do
    hover_at("nothing_defined(‸1)\n").to_s.should start_with("unknown (")
  end

  it "keeps Int32 for the literal of an operator assignment" do
    hover_at("page = 1\npage += ‸1\n").should eq(typed("Int32"))
  end

  it "keeps its own type for a returned literal (crystal rejects returning Int32 as Int64)" do
    hover_at("def ret : Int64\n  ‸1\nend\n").should eq(typed("Int32"))
  end

  it "keeps its own type for a symbol that is not an argument" do
    hover_at("x = :‸red\n").should eq(typed("Symbol"))
  end

  it "takes the parameter type of a constructor argument (crystal: autocasts to Int64)" do
    source = "struct P\n  def initialize(@x : Int64)\n  end\nend\n\nP.new(‸1)\n"
    hover_at(source).should eq(typed("Int64"))
  end

  it "takes the parameter type of a method argument on a typed receiver" do
    source = "class P\n  def add(n : Int64)\n  end\nend\n\nP.new.add(‸2)\n"
    hover_at(source).should eq(typed("Int64"))
  end

  it "takes the parameter type of a user-defined operator argument" do
    source = "class V\n  def +(other : Int64)\n  end\nend\n\nV.new + ‸1\n"
    hover_at(source).should eq(typed("Int64"))
  end

  it "takes the one enum when several overloads agree on it" do
    source = "enum Color\n  Red\nend\n\ndef paint(c : Color)\nend\n\n" \
             "def paint(c : Color, extra = 1)\nend\n\npaint(:‸red)\n"
    hover_at(source).should eq(typed("Color"))
  end

  it "takes the type declared for a local assigned later (crystal: Int64)" do
    hover_at("x2 : Int64\nx2 = ‸7\n").should eq(typed("Int64"))
  end

  it "takes the type of an uninitialized local assigned later (crystal: Int64)" do
    hover_at("x = uninitialized Int64\nx = ‸7\n").should eq(typed("Int64"))
  end

  it "keeps its own type for a local that is never declared (crystal: Int32)" do
    hover_at("x = ‸7\n").should eq(typed("Int32"))
  end

  it "takes the type the receiver binds a type variable to in a constructor (crystal)" do
    source = "class Gen(T)\n  def initialize(x : T)\n  end\nend\n\n"
    hover_at(source + "Gen(UInt8).new(‸7)\n").should eq(typed("UInt8"))
    hover_at(source + "Gen(Int64).new(‸7)\n").should eq(typed("Int64"))
  end

  it "takes the type the receiver binds a type variable to in a method call" do
    source = "class Gen(T)\n  def initialize(x : T)\n  end\n\n  def put(x : T)\n  end\nend\n\n"
    hover_at(source + "Gen(UInt8).new(1).put(‸7)\n").should eq(typed("UInt8"))
  end

  it "does not guess for a type variable the receiver does not bind" do
    source = "class Gen(T)\n  def initialize(x : T)\n  end\nend\n\n"
    hover_at(source + "Gen.new(‸7)\n").to_s.should start_with("unknown (free variable: ")
  end

  it "ignores overloads whose other arguments do not fit (crystal: UInt8)" do
    source = "class S(T)\n  def self.new(size : Int, value : T)\n  end\n\n" \
             "  def self.new(pointer : Pointer(T), size : Int)\n  end\nend\n\n"
    hover_at(source + "S(UInt8).new(3, ‸7)\n").should eq(typed("UInt8"))
  end

  it "takes the element type of a collection literal with a written type (crystal: UInt8)" do
    source = "class Bag(T)\n  def <<(x : T)\n  end\nend\n\n"
    hover_at(source + "Bag(UInt8){‸7}\n").should eq(typed("UInt8"))
  end

  it "takes the key and value types of a hash-like literal with a written type (crystal)" do
    source = "class Table(K, V)\n  def []=(k : K, v : V)\n  end\nend\n\n"
    hover_at(source + "Table(Int64, UInt8){‸7 => 8}\n").should eq(typed("Int64"))
    hover_at(source + "Table(Int64, UInt8){7 => ‸8}\n").should eq(typed("UInt8"))
  end
end

describe "hover and definition inside macro code" do
  source = "module Foo\n  BAR = 1\nend\n\nclass Baz\n  def hi\n  end\nend\n\n"

  it "still answers a constant path inside a macro expression" do
    hover_at(source + "def f\n  {{ Foo::BA‸R }}\nend\n").to_s.should contain("BAR")
  end

  it "still finds the definition of a path inside a macro expression" do
    position = marked(source + "def f\n  {{ Foo::BA‸R }}\nend\n")
    with_document(position.source) do |client|
      locations = client.definition(DOCUMENT_URI, position.line, position.character).result
      locations.try(&.raw).should_not be_nil
    end
  end

  it "answers a path inside a macro control block and a macro statement" do
    loop_source = source + "def f\n  {% for y in [Foo::BA‸R] %}{% end %}\nend\n"
    hover_at(loop_source).to_s.should contain("BAR")
    hover_at(source + "def f\n  {% a = Foo::BA‸R %}\nend\n").to_s.should contain("BAR")
  end

  it "replies null for calls and literals, which are macro-time values" do
    hover_at(source + "def f\n  {{ Baz.new.‸hi }}\nend\n").should be_nil
    hover_at(source + "def f\n  {{ Baz.‸new.hi }}\nend\n").should be_nil
    hover_at(source + "def f\n  {{ [1, ‸2].size }}\nend\n").should be_nil
  end
end

describe "hover on literals and their scopes and overloads" do
  it "keeps the literal's own type when a block parameter shadows a declared local (crystal)" do
    hover_at("z : Int64 = 0\n[1].each do |z|\n  z = ‸8\nend\n").should eq(typed("Int32"))
  end

  it "keeps the literal's own type when a proc parameter shadows a declared local (crystal)" do
    hover_at("z : Int64 = 0\npr = ->(z : Int32) { z = ‸8 }\n").should eq(typed("Int32"))
  end

  it "does not let a declaration inside a block reach the code after it (crystal: Int32)" do
    source = "def foo\n  yield\nend\n\nfoo { x : Int64 = 1 }\nx = ‸7\n"
    hover_at(source).should eq(typed("Int32"))
  end

  it "does not let one block's declaration reach a sibling block (crystal: Int32)" do
    source = "def foo\n  yield\nend\n\nfoo { x : Int64 = 1 }\nfoo { x = ‸7 }\n"
    hover_at(source).should eq(typed("Int32"))
  end

  it "finds a declaration in the same block (crystal: Int64)" do
    source = "def foo\n  yield\nend\n\nfoo do\n  x : Int64 = 1\n  x = ‸7\nend\n"
    hover_at(source).should eq(typed("Int64"))
  end

  it "finds a declaration in an enclosing scope from inside a block (crystal: Int64)" do
    hover_at("z : Int64 = 0\n[1].each do |q|\n  z = ‸7\nend\n").should eq(typed("Int64"))
  end

  it "points the definition of a local declared with uninitialized at the declaration" do
    with_document("x = uninitialized Int64\nx = 1\ny = x\n") do |client|
      locations = client.definition(DOCUMENT_URI, 2, 4).result
      locations.try(&.as_a?).try(&.map(&.["range"]["start"]["line"].as_i)).should eq([0])
    end
  end

  it "binds a bare generic collection's type variable to its own elements (crystal: Int8)" do
    source = "class Cx(T)\n  def <<(x : T)\n  end\nend\n\n"
    hover_at(source + "Cx{1_‸i8}\n").should eq(typed("Int8"))
    hover_at(source + "Cx{‸1, 2}\n").should eq(typed("Int32"))
  end

  it "ignores a named literal when overloads tie (crystal: ambiguous call)" do
    source = "def f(a : Int64, y : Int32)\nend\n\ndef f(a : Int8, y : String)\nend\n\n"
    text = hover_at(source + "f(‸1, y: 2)\n").to_s
    text.should start_with("unknown (ambiguous: ")
  end
end

describe "hover on collection literals with a written type and on declared locals" do
  container = "class Cx(T)\n  def <<(x : T)\n  end\nend\n\n"

  it "types the container from its written type (crystal: Array(Int64))" do
    hover_at("x = Array(Int64){7‸}\n").should eq(typed("Array(Int64)"))
    hover_at("x = Array(Int64)‸{7}\n").should eq(typed("Array(Int64)"))
  end

  it "types a user-defined container from its written type (crystal: Cx(Int64))" do
    hover_at(container + "x = Cx(Int64){7‸}\n").should eq(typed("Cx(Int64)"))
  end

  it "types a nested written container from its outer type" do
    hover_at("x = Array(Array(Int64)){[7_i64]‸}\n").should eq(typed("Array(Array(Int64))"))
  end

  it "types a variable assigned a collection with a written type" do
    hover_at("x = Array(Int64){7}\nputs ‸x\n").should eq(typed("Array(Int64)"))
  end

  it "infers a bare generic collection's type arguments from its elements (crystal: Cx(Int32))" do
    hover_at(container + "x = Cx{1‸}\n").should eq(typed("Cx(Int32)"))
  end

  it "infers the union of mixed elements for a bare generic collection (crystal)" do
    hover_at(container + "x = Cx{1, \"a\"‸}\n").should eq(typed("Cx(Int32 | String)"))
  end

  it "types a declared local assigned a literal as the declared type (crystal: Int64)" do
    hover_at("y : Int64\ny = 3\nputs ‸y\n").should eq(typed("Int64"))
  end

  it "types an uninitialized local assigned a literal as the declared type (crystal: Int64)" do
    hover_at("x = uninitialized Int64\nx = 15\nputs ‸x\n").should eq(typed("Int64"))
  end

  it "types a union-declared local assigned a literal as its member (crystal: Int64)" do
    hover_at("z : Int64 | String\nz = 3\nputs ‸z\n").should eq(typed("Int64"))
  end

  it "types a local declared outside a block and assigned inside it as the declared type" do
    hover_at("y : Int64\n[1].each do |q|\n  y = 3\n  puts ‸y\nend\n").should eq(typed("Int64"))
  end

  it "keeps the assigned literal's own type for a block parameter that shadows a declaration" do
    source = "z : Int64 = 0\n[1].each do |z|\n  z = 8\n  puts ‸z\nend\n"
    hover_at(source).should eq(typed("Int32"))
  end

  it "does not turn an unknown declared type back into the literal's type" do
    hover_at("x : Foo\nx = 7\nputs ‸x\n").to_s.should start_with("unknown (")
    hover_at("x : Foo\nx = ‸7\n").to_s.should start_with("unknown (")
  end

  it "infers a bare two-variable generic from its entries (crystal)" do
    table = "class Tab(K, V)\n  def []=(k : K, v : V)\n  end\nend\n\n"
    hover_at(table + "x = Tab{1 => \"a\"‸}\n").should eq(typed("Tab(Int32, String)"))
    hover_at(table + "x = Tab{1 => \"a\"}\nputs ‸x\n").should eq(typed("Tab(Int32, String)"))
  end

  it "does not guess for a bare generic with the wrong number of type variables (crystal)" do
    two = "class Two(A, B)\n  def <<(x : A)\n  end\nend\n\n"
    hover_at(two + "x = Two{1‸}\n").to_s.should start_with("unknown (no annotation: ")
  end

  it "keeps a non-generic collection name's written type (crystal: Pl)" do
    plain = "class Pl\n  def <<(x : Int64)\n  end\nend\n\n"
    hover_at(plain + "x = Pl{1‸}\n").should eq(typed("Pl"))
  end

  it "flow-types a local reassigned with a different type (crystal: Int32 then Int64)" do
    big = "def big : Int64\n  1_i64\nend\n\n"
    hover_at(big + "y = 1\ny = 2\nputs ‸y\ny = big\nputs y\n").should eq(typed("Int32"))
    hover_at(big + "y = 1\ny = 2\nputs y\ny = big\nputs ‸y\n").should eq(typed("Int64"))
  end
end
