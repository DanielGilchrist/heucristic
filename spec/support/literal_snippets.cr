record LiteralSnippet,
  klass : String,
  autocast : Bool,
  owned : String,
  inside : String,
  inside_owned : Bool

LITERAL_SNIPPETS = {
  LiteralSnippet.new("StringLiteral", false, "x = ‸\"ab\"\n", "x = \"a‸b\"\n", true),
  LiteralSnippet.new(
    "StringInterpolation", false, "x = ‸\"a\#{1}b\"\n", "x = \"‸a\#{1}b\"\n", true
  ),
  LiteralSnippet.new("CharLiteral", false, "x = ‸'c'\n", "x = '‸c'\n", true),
  LiteralSnippet.new("BoolLiteral", false, "x = ‸true\n", "x = tr‸ue\n", true),
  LiteralSnippet.new("NilLiteral", false, "x = ‸nil\n", "x = n‸il\n", true),
  LiteralSnippet.new("RegexLiteral", false, "x = ‸/ab/\n", "x = /a‸b/\n", true),
  LiteralSnippet.new("NumberLiteral", true, "x = ‸12\n", "x = 1‸2\n", true),
  LiteralSnippet.new("SymbolLiteral", true, "x = ‸:sym\n", "x = :s‸ym\n", true),
  LiteralSnippet.new("ArrayLiteral", false, "x = ‸[1, 2]\n", "x = [1,‸ 2]\n", false),
  LiteralSnippet.new("HashLiteral", false, "x = ‸{\"a\" => 1}\n", "x = {\"a\" =>‸ 1}\n", false),
  LiteralSnippet.new("TupleLiteral", false, "x = ‸{1, 2}\n", "x = {1,‸ 2}\n", false),
  LiteralSnippet.new("NamedTupleLiteral", false, "x = ‸{a: 1}\n", "x = {a:‸ 1}\n", false),
  LiteralSnippet.new("RangeLiteral", false, "x = 1‸..3\n", "x = 1‸ .. 3\n", false),
  LiteralSnippet.new("ProcLiteral", false, "x = ‸->{ 1 }\n", "x = ->{‸ 1 }\n", false),
}

record MarkedSource, source : String, line : Int32, column : Int32

def marked_source(marked : String) : MarkedSource
  offset = marked.index('‸')
  raise "no marker in #{marked.inspect}" unless offset

  before = marked[0, offset]
  line = before.count('\n') + 1
  column = offset - (before.rindex('\n').try(&.+(1)) || 0) + 1
  MarkedSource.new(marked.delete('‸'), line, column)
end
