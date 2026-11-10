require "../../spec_helper"

private def target_at(
  source : String,
  line : Int32,
  column : Int32,
) : Heucristic::Syntax::Target | Heucristic::Syntax::NoTarget
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Syntax::Cursor.find(
    tree, Heucristic::Document::Point.new(line, column), "a.cr", SPEC_CRYSTAL, source
  )
end

private def target_at_mark(
  marked : String,
) : Heucristic::Syntax::Target | Heucristic::Syntax::NoTarget
  position = marked_source(marked)
  target_at(position.source, position.line, position.column)
end

private def node_class(target : Heucristic::Syntax::Target | Heucristic::Syntax::NoTarget) : String?
  case target
  in Heucristic::Syntax::OnLiteral, Heucristic::Syntax::OnAutocast
    target.node.class.name
  in Heucristic::Syntax::OnDef, Heucristic::Syntax::OnCall, Heucristic::Syntax::OnPath,
     Heucristic::Syntax::OnVar, Heucristic::Syntax::OnInstanceVar, Heucristic::Syntax::OnRequire,
     Heucristic::Syntax::NoTarget
    nil
  end
end

private def literal_class(marked : String) : String?
  target_at_mark(marked).as?(Heucristic::Syntax::OnLiteral).try(&.node.class.name)
end

private def autocast_class(marked : String) : String?
  target_at_mark(marked).as?(Heucristic::Syntax::OnAutocast).try(&.node.class.name)
end

private def placement_at(marked : String) : Heucristic::Syntax::Placement?
  target_at_mark(marked).as?(Heucristic::Syntax::OnAutocast).try(&.placement)
end

private def placement_summary(marked : String) : String
  placement = placement_at(marked)
  case placement
  in Heucristic::Syntax::FreePlacement        then "free"
  in Heucristic::Syntax::DeclaredPlacement    then "declared #{placement.type}"
  in Heucristic::Syntax::InstanceVarPlacement then "instance variable #{placement.name}"
  in Heucristic::Syntax::LocalPlacement       then "local #{placement.name}"
  in Heucristic::Syntax::ArgumentPlacement
    "argument #{placement.call.name} #{slot_summary(placement.slot)}"
  in Heucristic::Syntax::ConstructedPlacement
    "constructed #{placement.type} #{placement.operation} #{placement.slot.index}"
  in Nil then "none"
  end
end

private def slot_summary(slot : Heucristic::Syntax::Slot) : String
  case slot
  in Heucristic::Syntax::PositionalSlot then "at #{slot.index}"
  in Heucristic::Syntax::NamedSlot      then "named #{slot.name}"
  end
end

private def no_target?(marked : String) : Bool
  target_at_mark(marked).is_a?(Heucristic::Syntax::NoTarget)
end

describe Heucristic::Syntax::Cursor do
  source = <<-'CR'
    def greet(name : String) : String
      "hi #{name}"
    end

    greet("x")
    CR

  it "finds a def by its name" do
    target = target_at(source, 1, 6)
    target.should be_a(Heucristic::Syntax::OnDef)
  end

  it "finds a call inside a macro if whose flag it cannot decide" do
    flagged = <<-CR
      def run
        {% if flag?(:custom) %}
          greet("a")
        {% else %}
          shout("b")
        {% end %}
      end
      CR
    taken = target_at(flagged, 3, 6)
    taken.should be_a(Heucristic::Syntax::OnCall)
    taken.as(Heucristic::Syntax::OnCall).node.name.should eq("greet")
    skipped = target_at(flagged, 5, 6)
    skipped.should be_a(Heucristic::Syntax::OnCall)
    skipped.as(Heucristic::Syntax::OnCall).node.name.should eq("shout")
  end

  it "keeps parameters as variables inside an expanded macro region" do
    region = <<-CR
      class Usage
        def initialize(usage)
          {% if true %}
            @max = usage.ru_maxrss
          {% end %}
        end
      end
      CR
    tree = Heucristic::Syntax.parse(region, "a.cr")
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    uses = Heucristic::Syntax::Uses.in(tree, "a.cr", SPEC_CRYSTAL)
    receivers = uses.calls.select(&.call.name.==("ru_maxrss")).map(&.call.obj.class.name)
    receivers.should eq(["Crystal::Var"])
  end

  it "finds a call by its name" do
    target = target_at(source, 5, 3)
    target.should be_a(Heucristic::Syntax::OnCall)
  end

  it "finds a literal argument of a call but not the parenthesis around it" do
    target_at(source, 5, 3).should be_a(Heucristic::Syntax::OnCall)
    target_at(source, 5, 8).should be_a(Heucristic::Syntax::OnLiteral)
    target_at(source, 5, 6).should be_a(Heucristic::Syntax::NoTarget)
  end

  it "does not match the keyword" do
    target_at(source, 1, 2).should be_a(Heucristic::Syntax::NoTarget)
  end

  nested = <<-CR
    module Outer
      class Inner
        def build(other : Other::Thing) : Inner
          Inner.new
        end
      end
    end
    CR

  it "finds a constant path and records the enclosing namespaces" do
    target = target_at(nested, 4, 7)
    target.should be_a(Heucristic::Syntax::OnPath)
    enclosing = target.as?(Heucristic::Syntax::OnPath).try(&.context.enclosing.map(&.name))
    enclosing.should eq(["Outer", "Outer::Inner"])
  end

  it "finds a path inside a type restriction" do
    target = target_at(nested, 3, 23)
    target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Other::Thing")
  end

  it "records which segment of a path the point is on" do
    source = "x = Outer::Inner::Thing\n"
    first = target_at(source, 1, 6).as?(Heucristic::Syntax::OnPath)
    middle = target_at(source, 1, 13).as?(Heucristic::Syntax::OnPath)
    last = target_at(source, 1, 20).as?(Heucristic::Syntax::OnPath)
    {first.try(&.segment), middle.try(&.segment), last.try(&.segment)}.should eq({0, 1, 2})
  end

  describe "index calls" do
    {"a[idx]", "a[idx]?", "a[idx] = 1"}.each do |expression|
      it "finds the argument inside #{expression}, not the index call" do
        source = "def f(a, idx)\n  #{expression}\nend\n"
        target = target_at(source, 2, 5).as?(Heucristic::Syntax::OnVar)
        target.try(&.name).should eq("idx")
      end

      it "finds the index call on the opening bracket of #{expression}" do
        source = "def f(a, idx)\n  #{expression}\nend\n"
        target = target_at(source, 2, 4).as?(Heucristic::Syntax::OnCall)
        target.try(&.node.name.starts_with?("[]")).should be_true
      end
    end

    it "finds the index call on the closing bracket" do
      source = "def f(a, idx)\n  a[idx]\nend\n"
      target = target_at(source, 2, 8).as?(Heucristic::Syntax::OnCall)
      target.try(&.node.name).should eq("[]")
    end

    it "finds the innermost argument of a nested index" do
      source = "def f(a, b, c)\n  a[b[c]]\nend\n"
      target = target_at(source, 2, 7).as?(Heucristic::Syntax::OnVar)
      target.try(&.name).should eq("c")
    end
  end

  it "finds the name of an alias declaration" do
    source = "module M\n  alias Query = Hash(String, String)\nend\n"
    target = target_at(source, 2, 10).as?(Heucristic::Syntax::OnPath)
    target.try(&.node.to_s).should eq("Query")
    target.try(&.context.enclosing.map(&.name)).should eq(["M"])
  end

  it "still finds the paths in an alias value" do
    source = "alias Query = Hash(String, Int32)\n"
    target_at(source, 1, 15).as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Hash")
  end

  describe "scalar literals" do
    {
      {"a string", "x = \"‸ab\"\n", "Crystal::StringLiteral"},
      {"the closing quote of a string", "x = \"ab‸\"\n", "Crystal::StringLiteral"},
      {"an interpolated string's text", "x = \"‸a\#{1}b\"\n", "Crystal::StringInterpolation"},
      {"a char", "x = '‸c'\n", "Crystal::CharLiteral"},
      {"a bool", "x = tr‸ue\n", "Crystal::BoolLiteral"},
      {"nil", "x = n‸il\n", "Crystal::NilLiteral"},
      {"a regex's source", "x = /a‸b/i\n", "Crystal::RegexLiteral"},
      {"a regex's flag", "x = /ab/‸i\n", "Crystal::RegexLiteral"},
      {"a multi-line string", "x = \"ab\nc‸d\"\n", "Crystal::StringLiteral"},
      {"a heredoc's opener", "x = <‸<-X\n  hi\n  X\n", "Crystal::StringInterpolation"},
      {"a heredoc's body", "x = <<-X\n  h‸i\n  X\n", "Crystal::StringInterpolation"},
      {"a heredoc's terminator", "x = <<-X\n  hi\n  ‸X\n", "Crystal::StringInterpolation"},
    }.each do |description, marked, kind|
      it "finds #{description}" do
        literal_class(marked).should eq(kind)
      end
    end

    it "keeps the variable inside an interpolation" do
      target = target_at_mark("def f(user_id)\n  \"/leave/\#{‸user_id}\"\nend\n")
      target.as?(Heucristic::Syntax::OnVar).try(&.name).should eq("user_id")
    end

    it "finds the string around an interpolation" do
      marked = "def f(a)\n  \"/le‸ave/\#{a}\"\nend\n"
      literal_class(marked).should eq("Crystal::StringInterpolation")
    end

    it "keeps the variable inside a regex interpolation" do
      target = target_at_mark("def f(y)\n  /a\#{‸y}b/\nend\n")
      target.as?(Heucristic::Syntax::OnVar).try(&.name).should eq("y")
    end

    it "finds the regex rather than its source string" do
      literal_class("x = /‸ab/\n").should eq("Crystal::RegexLiteral")
    end
  end

  describe "heredocs among other arguments" do
    it "finds a number after the opener" do
      autocast_class("foo(<<-X, ‸1)\n  body\n  X\n").should eq("Crystal::NumberLiteral")
    end

    it "finds nothing on the comma after the opener" do
      no_target?("foo(<<-X,‸ 1)\n  body\n  X\n").should be_true
    end

    it "finds the heredoc on its opener" do
      literal_class("foo(<<-‸X, 1)\n  body\n  X\n").should eq("Crystal::StringInterpolation")
    end

    it "finds a number inside an array after the opener" do
      autocast_class("foo(<<-X, [1, ‸2])\n  body\n  X\n").should eq("Crystal::NumberLiteral")
    end

    it "finds a number after a method called on the heredoc" do
      autocast_class("foo(<<-X.strip, ‸9)\n  body\n  X\n").should eq("Crystal::NumberLiteral")
    end
  end

  describe "autocastable literals" do
    {
      {"a number", "x = ‸12\n", "Crystal::NumberLiteral"},
      {"a number with a suffix", "x = 1_‸i64\n", "Crystal::NumberLiteral"},
      {"a negative number's sign", "x = ‸-1\n", "Crystal::NumberLiteral"},
      {"a symbol", "x = :s‸ym\n", "Crystal::SymbolLiteral"},
      {"a quoted symbol", "x = :\"q ‸r\"\n", "Crystal::SymbolLiteral"},
    }.each do |description, marked, kind|
      it "finds #{description}" do
        autocast_class(marked).should eq(kind)
      end
    end

    it "finds a quoted symbol argument as one token" do
      autocast_class("foo(:\"q ‸r\")\n").should eq("Crystal::SymbolLiteral")
      autocast_class("foo(:\"q r\"‸)\n").should be_nil
    end

    it "finds a symbol argument that names a declaration" do
      autocast_class("attr_reader :na‸me\n").should eq("Crystal::SymbolLiteral")
    end
  end

  describe "container literals" do
    {
      {"an array's opening bracket", "x = ‸[1, 2]\n", "Crystal::ArrayLiteral"},
      {"an array's closing bracket", "x = [1, 2‸]\n", "Crystal::ArrayLiteral"},
      {"an empty array's `of`", "x = [] o‸f Int64\n", "Crystal::ArrayLiteral"},
      {"a word array's opening token", "x = %‸w(a b)\n", "Crystal::ArrayLiteral"},
      {"a hash's opening brace", "x = ‸{\"a\" => 1}\n", "Crystal::HashLiteral"},
      {"a hash's closing brace", "x = {\"a\" => 1‸}\n", "Crystal::HashLiteral"},
      {"an empty hash's `of`", "x = {} o‸f String => Int32\n", "Crystal::HashLiteral"},
      {"a tuple's brace", "x = ‸{1, 2}\n", "Crystal::TupleLiteral"},
      {"a named tuple's brace", "x = {a: 1‸}\n", "Crystal::NamedTupleLiteral"},
      {"a range's operator", "x = 1.‸.3\n", "Crystal::RangeLiteral"},
      {"an exclusive range's operator", "x = 1..‸.3\n", "Crystal::RangeLiteral"},
      {"a proc's arrow", "x = -‸>(a : Int32) { a }\n", "Crystal::ProcLiteral"},
    }.each do |description, marked, kind|
      it "finds #{description}" do
        literal_class(marked).should eq(kind)
      end
    end

    {
      {"between array elements", "x = [1,‸ 2]\n"},
      {"on the indentation of an array's next line", "x = [1,\n‸  2]\n"},
      {"inside a hash", "x = {\"a\" =>‸ 1}\n"},
      {"between a tuple's elements", "x = {1,‸ 2}\n"},
      {"inside an empty array", "x = [‸ ] of Int64\n"},
      {"beside a range's operator", "x = 1‸ .. 3\n"},
      {"inside a proc's body braces", "x = ->{‸ 1 }\n"},
    }.each do |description, marked|
      it "finds nothing #{description}" do
        literal_class(marked).should be_nil
      end
    end

    it "finds the opening brace of a collection with a written type" do
      literal_class("x = Array(Int64)‸{7}\n").should eq("Crystal::ArrayLiteral")
      literal_class("x = Hash(Int64, UInt8)‸{7 => 8}\n").should eq("Crystal::HashLiteral")
    end

    it "finds the element rather than the array it sits in" do
      autocast_class("x = [1, ‸2]\n").should eq("Crystal::NumberLiteral")
    end

    it "keeps the variable inside an array" do
      target_at_mark("def f(x)\n  [‸x]\nend\n").as?(Heucristic::Syntax::OnVar)
        .try(&.name).should eq("x")
    end

    it "keeps a call inside a hash value" do
      target = target_at_mark("x = {\"a\" => Utils::Time.iso_‸date(1)}\n")
      target.as?(Heucristic::Syntax::OnCall).try(&.node.name).should eq("iso_date")
    end

    it "keeps the path inside a hash value" do
      target = target_at_mark("x = {\"a\" => Uti‸ls::Time.iso_date(1)}\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Utils::Time")
    end

    it "finds a range between variables only on its operator" do
      literal_class("def f(a, b)\n  a‸..b\nend\n").should eq("Crystal::RangeLiteral")
      literal_class("def f(a, b)\n  a.‸.b\nend\n").should eq("Crystal::RangeLiteral")
    end
  end

  describe "blank space" do
    it "finds nothing on trailing blank space after a statement" do
      no_target?("x = [1]  ‸ \n").should be_true
    end

    it "finds nothing on an empty line between statements" do
      no_target?("x = 1\n‸\ny = 2\n").should be_true
    end

    it "finds nothing on the operator between an assignment's sides" do
      no_target?("x ‸= 1\n").should be_true
    end

    it "finds nothing on punctuation outside a literal" do
      no_target?("puts(1‸)\n").should be_true
    end
  end

  describe "type positions" do
    it "finds nothing on a number in a generic type argument" do
      no_target?("def f(a : StaticArray(Int32, ‸3))\nend\n").should be_true
    end

    it "finds nothing on the number of a static array type declared on an ivar" do
      no_target?("class A\n  @buf : UInt8[‸4]\nend\n").should be_true
    end

    it "finds nothing on the number of an uninitialized static array" do
      no_target?("x = uninitialized UInt8[‸8]\n").should be_true
    end

    it "skips a type argument number even when the parser gave it an end location" do
      source = "def f(a : StaticArray(Int32, 3))\nend\n"
      tree = Heucristic::Syntax.parse(source, "a.cr")
      raise "unexpected syntax error" unless tree.is_a?(Crystal::Def)

      number = tree.args[0].restriction.as(Crystal::Generic).type_vars[1]
      number.end_location = number.location
      found = Heucristic::Syntax::Cursor.find(
        tree, Heucristic::Document::Point.new(1, 30), "a.cr", SPEC_CRYSTAL, source
      )
      found.should be_a(Heucristic::Syntax::NoTarget)
    end

    it "still finds the type name in a generic" do
      target = target_at_mark("def f(a : Static‸Array(Int32, 3))\nend\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("StaticArray")
    end

    it "still finds a type argument that is not a literal" do
      target = target_at_mark("def f(a : StaticArray(In‸t32, 3))\nend\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Int32")
    end

    it "finds a number argument of a call that looks like a type" do
      autocast_class("x = UInt8[‸4]\n").should eq("Crystal::NumberLiteral")
    end
  end

  describe "macros" do
    it "finds nothing on a literal inside a macro expression" do
      no_target?("def f\n  {{ [1, ‸2].size }}\nend\n").should be_true
    end

    it "finds nothing on a literal inside a macro control block" do
      no_target?("def f\n  {% for x in [1, ‸2] %}{% end %}\nend\n").should be_true
    end

    it "finds nothing on a call inside a macro expression" do
      no_target?("def f\n  {{ Baz.new.‸hi }}\nend\n").should be_true
      no_target?("def f\n  {{ Baz.‸new.hi }}\nend\n").should be_true
    end

    it "finds nothing on a variable inside a macro control block" do
      no_target?("def f\n  {% for y in [1] %}{{ ‸y }}{% end %}\nend\n").should be_true
    end

    it "still finds a path inside a macro expression" do
      target = target_at_mark("def f\n  {{ Foo::BA‸R }}\nend\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Foo::BAR")
    end

    it "still finds a path inside a macro control block" do
      target = target_at_mark("def f\n  {% for y in [Foo::BA‸R] %}{% end %}\nend\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Foo::BAR")
    end

    it "still finds a path assigned inside a macro statement" do
      target = target_at_mark("def f\n  {% a = Foo::BA‸R %}\nend\n")
      target.as?(Heucristic::Syntax::OnPath).try(&.node.to_s).should eq("Foo::BAR")
    end
  end

  describe "placements" do
    it "places a literal with a declared type" do
      placement_at("x : Int64 = ‸1\n").should be_a(Heucristic::Syntax::DeclaredPlacement)
    end

    it "places array elements by the `of` type" do
      placement_at("x = [‸1, 2] of Int64\n").should be_a(Heucristic::Syntax::DeclaredPlacement)
    end

    it "places hash keys and values by the `of` types" do
      placement_summary("x = {‸1 => 2} of Int64 => Int8\n").should eq("declared Int64")
      placement_summary("x = {1 => ‸2} of Int64 => Int8\n").should eq("declared Int8")
    end

    it "places a default value by its parameter's restriction" do
      placement_at("def g(z : Int8 = ‸1)\nend\n").should be_a(Heucristic::Syntax::DeclaredPlacement)
    end

    it "leaves an unrestricted default value free" do
      placement_at("def g(z = ‸1)\nend\n").should be_a(Heucristic::Syntax::FreePlacement)
    end

    it "places an enum member by the enum's base type" do
      placement_summary("enum Color : UInt8\n  Red = ‸1\nend\n").should eq("declared UInt8")
    end

    it "leaves an enum member without a base type free" do
      placement_at("enum Color\n  Red = ‸1\nend\n").should be_a(Heucristic::Syntax::FreePlacement)
    end

    it "places positional and named call arguments by slot" do
      placement_summary("f(1, ‸2)\n").should eq("argument f at 1")
      placement_summary("f(color: ‸:red)\n").should eq("argument f named color")
    end

    it "places a local variable assignment by the variable" do
      placement_summary("x2 : Int64\nx2 = ‸7\n").should eq("local x2")
    end

    it "places a typed collection literal element by the operation it is constructed with" do
      placement_summary("x = Array(Int64){‸7, 8}\n").should eq("constructed Array(Int64) Append 0")
      placement_summary("x = Hash(Int64, UInt8){‸7 => 8}\n")
        .should eq("constructed Hash(Int64, UInt8) Store 0")
      placement_summary("x = Hash(Int64, UInt8){7 => ‸8}\n")
        .should eq("constructed Hash(Int64, UInt8) Store 1")
    end

    it "places an instance variable assignment by the variable" do
      source = "class A\n  def initialize\n    @x = ‸1\n  end\nend\n"
      placement_summary(source).should eq("instance variable @x")
    end

    it "leaves an operator assignment, a receiver and an element free" do
      [
        "x = 0\nx += ‸1\n", "‸1.to_s\n", "x = [‸1]\n", "x = {a: ‸1}\n",
        "x = {‸1, 2}\n",
      ].each do |marked|
        placement_at(marked).should be_a(Heucristic::Syntax::FreePlacement)
      end
    end

    it "treats an annotation argument as a free literal" do
      placement_at("@[Foo(‸1)]\nclass A\nend\n").should be_a(Heucristic::Syntax::FreePlacement)
      placement_at("@[Foo(bar: ‸1)]\nclass A\nend\n").should be_a(Heucristic::Syntax::FreePlacement)
    end
  end

  describe "every literal AST class" do
    LITERAL_SNIPPETS.each do |snippet|
      it "finds #{snippet.klass} where it starts to own source" do
        target = target_at_mark(snippet.owned)
        found = if snippet.autocast
                  target.as?(Heucristic::Syntax::OnAutocast).try(&.node.class.name)
                else
                  target.as?(Heucristic::Syntax::OnLiteral).try(&.node.class.name)
                end
        found.should eq("Crystal::#{snippet.klass}")
      end

      it "gives #{snippet.klass} the expected target between its tokens" do
        found = node_class(target_at_mark(snippet.inside))
        found.should eq(snippet.inside_owned ? "Crystal::#{snippet.klass}" : nil)
      end

      it "gives #{snippet.klass} no target as a type argument" do
        position = marked_source(snippet.owned)
        assignment = Heucristic::Syntax.parse(position.source, "a.cr")
        raise "unexpected syntax error" unless assignment.is_a?(Crystal::Assign)

        generic = Crystal::Generic.new(Crystal::Path.new("Foo"), [assignment.value])
        found = Heucristic::Syntax::Cursor.find(
          generic,
          Heucristic::Document::Point.new(position.line, position.column),
          "a.cr",
          SPEC_CRYSTAL,
          position.source,
        )
        found.should be_a(Heucristic::Syntax::NoTarget)
      end
    end
  end
end
