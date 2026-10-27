require "json"
require "yaml"
require "log"
require "colorize"
require "spec"
require "compiler/crystal/syntax"

macro probe(expression)
end

record Point, x : Int32 do
  include JSON::Serializable
  include YAML::Serializable
end

enum Colour
  Red
  Green
end

struct Version
  include Comparable(Version)

  def initialize(@number : Int32) : Nil
  end

  def <=>(other : Version) : Int32
    @number <=> other.@number
  end
end

class Array(T)
  def __probe_protected : Nil
    probe to_lookup_hash { |item| item }
    probe to_unsafe_slice
    probe to_unsafe_slice(0, 1)
  end
end

class Visitor < Crystal::Visitor
  def visit(node : Crystal::ASTNode) : Bool
    true
  end
end

one = 1
two = 2
letter = 'a'
ints = [1, 2, 3]
strings = ["a", "b"]
words : Array(String) = ["a", "b"]
set : Set(Int32) = Set(Int32).new
hash = {"a" => 1}
deque : Deque(Int32) = Deque(Int32).new
bytes : Slice(UInt8) = Slice(UInt8).new(2)
tuple = {1, "a"}
pair = {1, 2}
range = 1..3
iterator : Iterator(Int32) = ints.each
indexable : Indexable(Int32) = ints
enumerable : Enumerable(Int32) = set
io = IO::Memory.new
file_descriptor : IO::FileDescriptor = STDIN
version = Version.new(1)
pointer : Pointer(Int32) = Pointer(Int32).malloc(1)
metadata : Log::Metadata = Log::Metadata.build({a: 1})
mutex : Sync::Mutex = Sync::Mutex.new
info : File::Info = File.info(".")
location : Crystal::Location = Crystal::Location.new("a.cr", 1, 1)
node : Crystal::ASTNode = Crystal::Nop.new
nilable_cast : Crystal::NilableCast = Crystal::NilableCast.new(Crystal::Nop.new, Crystal::Nop.new)
parser : Crystal::Parser = Crystal::Parser.new("1")
maybe : Int32? = nil
nothing = nil
colour = Colour::Red

probe Array.new(2, &.to_s)
probe(ints[0..1] = 5)
probe(ints[0..1] = [5])
probe(ints[0, 1] = [5])
probe(ints[0, 1] = 5)
probe ints.[]=(5, index: 0, count: 1)
probe ints.[]=([5], index: 0, count: 1)
probe ints <=> [1]
words.__probe_protected
probe ints.index(1, 0)
probe ints.map_with_index { |value, index| value + index }
probe ints.product(strings)

probe "a".colorize(Colorize::ColorANSI::Red)
probe "a".colorize(:red)
probe "a".colorize(1_u8)
probe "a".colorize(1_u8, 2_u8, 3_u8)

probe version <= Version.new(2)
probe version == Version.new(2)
probe version >= Version.new(2)
probe version.clamp(Version.new(0), Version.new(2))
probe version.clamp(Version.new(0)..Version.new(2))

probe node.accept(Visitor.new)
probe node.at(location)
probe node.at(Crystal::Nop.new)
probe location.column_number
probe location.filename
probe location.line_number
probe nilable_cast.to
probe parser.parse

probe deque << 1
probe deque.push(1)
probe deque.shift?

probe Dir.each_child(".", &.size)

probe colour == Colour::Green
probe colour == 1

probe set.chunks(&.even?)
probe set.compact_map { |value| value.to_s if value > 0 }
probe set.each_cons(2, &.size)
probe set.each_slice(2, &.size)
probe set.each_with_index(1_i64) { |_, index| index }
probe set.each { |value| value }
probe enumerable.each { |value| value }
probe set.find(0) { |value| value > 1 }
probe set.flat_map { |value| [value.to_s] }
probe set.group_by(&.even?)
probe set.in_groups_of(2, 0, &.size)
probe set.in_groups_of(2, "x")
probe set.join(io, ",") { |value, output| output << value }
probe set.join(",") { |value| value + 1 }
probe set.join(",", io) { |value, output| output << value }
probe set.reduce? { |memo, value| memo + value }
probe set.reduce { |memo, value| memo + value }
probe set.reduce("") { |memo, value| memo + value.to_s }
probe set.reject { |value| value > 1 }
probe set.reject(String)
probe set.select { |value| value > 1 }
probe set.skip(1)
probe set.sum
probe set.sum(&.to_f)
probe set.to_h { |value| {value, value.to_s} }
probe set.zip?(strings) { |values| values }
probe set.zip(strings) { |values| values }

probe info.directory?
probe info.file?

probe File.open("/dev/null", &.size)
probe File.write("/dev/null", "x")

probe Hash(String, Int32).new(0, 8)
probe Hash(String, Int32).new(8) { |_, key| key.size }
probe Hash.zip(strings, ints)
probe hash["a"]?
probe hash["a"]
probe hash.dig?("a")
probe hash.dig("a")
probe hash.each_key
probe hash.each_key { |key| key }
probe hash.each_value
probe hash.each_value { |value| value }
probe hash.each
probe hash.reject! { |_, value| value > 1 }

probe deque[0]?
probe deque[0]
probe ints.bsearch_index { |value, _| value > 1 }
probe ints.bsearch { |value| value > 1 }
probe ints.combinations(2)
probe deque.dig?(0)
probe deque.dig(0)
probe ints.each_combination(2)
probe deque.each_index
probe deque.each_index(start: 0, count: 1) { |index| index }
probe ints.each_permutation(2)
probe ints.each_repeated_combination(2)
probe deque.each { |value| value }
probe deque.each(start: 0, count: 1) { |value| value }
probe deque.each(within: 0..1) { |value| value }
probe ints.find!(0) { |value| value > 1 }
probe ints.index!(1, 0)
probe ints.index!(0) { |value| value > 1 }
probe ints.index(0) { |value| value > 1 }
probe deque.reverse_each
probe ints.rindex!(2) { |value| value > 1 }
probe ints.rindex!(1, 2)
probe ints.rindex(2) { |value| value > 1 }
probe ints.rindex(1, 2)
probe ints.sample(Random.new)
probe deque.size
probe indexable.each { |value| value }
probe indexable.index(1, 0)
probe indexable.size
probe indexable.each
probe indexable.unsafe_fetch(0)
probe ints.unsafe_fetch(0)

probe one === letter
probe ~1

probe file_descriptor.noecho(&.fd)

probe io.flush
probe io.read_bytes(Int32, IO::ByteFormat::LittleEndian)

probe set.each_slice(2)
probe set.each_with_index(1_i64)

probe Iterator(Int32).empty
probe Iterator.of { 1 }
probe Iterator.of(1)
probe Iterator.stop
probe iterator.accumulate
probe iterator.accumulate { |memo, value| memo + value }
probe iterator.accumulate("") { |memo, value| memo + value.to_s }
probe iterator.accumulate(0.5)
probe iterator.chain(strings.each)
probe iterator.chunk_while { |left, right| left < right }
probe iterator.chunk(&.even?)
probe iterator.compact_map { |value| value.to_s if value > 1 }
probe iterator.cons(2)
probe iterator.cycle
probe iterator.cycle(2)
probe iterator.each_slice(2)
probe iterator.each
probe iterator.first(2)
probe iterator.flat_map { |value| [value.to_s] }
probe iterator.map(&.to_s)
probe iterator.next
probe iterator.reject { |value| value > 1 }
probe iterator.reject(1)
probe iterator.select { |value| value > 1 }
probe iterator.select(1)
probe iterator.select(Int32)
probe iterator.skip_while { |value| value < 2 }
probe iterator.skip(1)
probe iterator.slice_after(1)
probe iterator.slice_after { |value| value > 1 }
probe iterator.slice_before(1)
probe iterator.slice_before { |value| value > 1 }
probe iterator.slice_when { |left, right| left > right }
probe iterator.slice(2)
probe iterator.step(2)
probe iterator.stop
probe iterator.take_while { |value| value < 2 }
probe iterator.tap { |value| value }
probe iterator.uniq
probe iterator.uniq(&.even?)
probe iterator.with_index(1_i64) { |_, index| index }
probe iterator.with_index(1_i64)

probe JSON.build { |json| json.object { json.field("a") { 1 } } }
probe JSON.build(io, &.number(1))

probe gets
probe spawn { 1 }

probe metadata.each { |entry| entry }

probe Log.setup { |configuration| configuration }
probe Log.setup(:info)

probe Math.max(1, 2.5)
probe Math.min(1, 2.5)

probe 1.5.round(1, 10, mode: :to_zero)

probe nothing == nil
probe nothing == one
probe maybe.try(&.to_s)
probe nothing.try { |value| value }
probe one != two
probe io == io
probe io === io
probe 1.tap { |value| value }
probe 1.try(&.to_s)
probe io == IO::Memory.new
probe io == 1
probe io != io
probe version == 1
probe one == two

probe pointer[0]

probe range.map(&.to_s)

probe Point.from_json(%({"a": {"x": 1}}), root: "a")
probe Point.from_json(%({"x": 1}))
probe Point.from_yaml("x: 1")

probe bytes.index(1_u8, 0)

probe be_close(1.0, 0.1)
probe be_empty
probe be_false
probe be_falsey
probe be_nil
probe be_true
probe be_truthy
probe be
probe be(1)
probe contain(1)
probe end_with("a")
probe eq(1)
probe match(/a/)
probe start_with("a")
probe fail("x", "a.cr", 1)

probe String.build { |builder| builder << 1 }
probe "a".each_byte
probe "a".each_byte { |byte| byte }
probe "a".rindex('a', 0)
probe "a b".split(&.size)
probe "a b".split(' ', &.size)
probe "a b".split(" ", &.size)
probe "1".to_i?(10, true, true, true, true, true)
probe "1".to_i(10, true, true, true, true, true)

probe mutex.synchronize { 1 }

probe tuple[0]?
probe tuple[0]
probe pair <=> pair
probe pair <=> {1, 2, 3}
probe pair == pair
probe pair == {1}
probe pair == 1
probe pair === pair
probe pair === {1}
probe tuple.at(0)
probe tuple.clone
probe tuple.map(&.to_s)
probe tuple.reverse_each { |value| value }
probe tuple.size
probe tuple.to_a(&.to_s)
probe tuple.unsafe_fetch(0)

probe io.dup
probe 1.dup

JSON.build do |json|
  probe json.object { 1 }
  json.object do
    probe json.field("a") { 1 }
  end
end
