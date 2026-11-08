require "../../spec_helper"

private SOURCE = <<-CR
  module Shapes
    class Circle
      def initialize(@radius : Float64) : Nil
      end
    end
  end

  class Canvas
    include Shapes

    @title : String

    def initialize(@width : Int32, height) : Nil
      @title = "c"
    end

    def draw(shape : Circle, label, count : Int32? = nil) : Nil
      scale : Float64 = 1.0
      shape
    end

    def self.build : Canvas
      new(1, 2)
    end
  end

  def top
  end
  CR

private def receiver_of(marker : String) : String
  tree = Heucristic::Syntax.parse(SOURCE, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  text = Heucristic::Document::Text.new(SOURCE)
  workspace.update(Heucristic::Index::Collector.collect("a.cr", text, tree, SPEC_CRYSTAL))
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  shims = Heucristic::Index::Shims.new
  receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)

  line = SOURCE.lines.index!(&.includes?(marker)) + 1
  column = SOURCE.lines[line - 1].index!(marker) + 1
  target = Heucristic::Syntax::Cursor.find(
    tree, Heucristic::Document::Point.new(line, column), "a.cr", SPEC_CRYSTAL, SOURCE
  )
  case target
  in Heucristic::Syntax::OnCall        then receiver.of_call(target.node, target.context).to_s
  in Heucristic::Syntax::OnVar         then receiver.variable(target.name, target.context).to_s
  in Heucristic::Syntax::OnInstanceVar then receiver.instance_var(target.name, target.context).to_s
  in Heucristic::Syntax::OnDef,
     Heucristic::Syntax::OnPath,
     Heucristic::Syntax::OnName,
     Heucristic::Syntax::OnRequire,
     Nil
    raise "cursor did not land on a call or variable at #{marker.inspect}"
  end
end

describe Heucristic::Resolve::Receiver do
  it "types a parameter from its restriction, resolved through the owner's ancestors" do
    receiver_at(SOURCE, 19, 5).should eq("Shapes::Circle")
  end

  it "types a local from its declaration" do
    receiver_of("scale").should eq("Float64")
  end

  it "resolves a nilable parameter to a union" do
    receiver_of("count").should eq("Int32 | Nil")
  end

  it "says so when a parameter has no restriction" do
    receiver_of("label").should eq(
      "unknown (no annotation: parameter label has no type restriction)"
    )
  end

  it "types a declared instance variable" do
    receiver_of("@title = ").should eq("String")
  end

  it "types an instance variable declared through a parameter" do
    receiver_of("@width").should eq("Int32")
  end

  it "types the implicit receiver of a call inside a class method as the metaclass" do
    receiver_of("new(1, 2)").should eq("Canvas.class")
  end
end

describe Heucristic::Resolve::Receiver, "expressions" do
  source = <<-CR
    class Thing
      def go(x : Int32, y) : Nil
        Thing.new.go(1, 2)
        Thing.go(1, 2)
        "s".size
        1.5.abs
        y.size
        (x.as(String)).size
      end
    end
    CR

  it "types Const.new as an instance and a bare constant as the metaclass" do
    receiver_at(source, 3, 15).should eq("Thing")
    receiver_at(source, 4, 11).should eq("Thing.class")
  end

  it "types literals" do
    receiver_at(source, 5, 9).should eq("String")
    receiver_at(source, 6, 9).should eq("Float64")
  end

  it "does not guess the result of a call on an unannotated variable" do
    receiver_at(source, 7, 7).should eq(
      "unknown (no annotation: parameter y has no type restriction)"
    )
  end

  it "trusts a cast" do
    receiver_at(source, 8, 20).should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "assignments" do
  source = <<-CR
    class Store
    end

    class Session
      def initialize : Nil
        @store = Store.new
        @mixed = Store.new
      end

      def reset : Nil
        @mixed = nil
        @store = build
      end

      def run(input : String) : Nil
        local = Store.new
        local.size
        copy = input
        copy.size
        either = Store.new
        either = 1
        either.size
        opaque = build
        opaque.size
        @store.size
        @mixed.size
      end
    end
    CR

  it "types a local from an evident assignment" do
    receiver_at(source, 17, 11).should eq("Store")
  end

  it "types a local assigned from an annotated parameter" do
    receiver_at(source, 19, 10).should eq("String")
  end

  it "uses the latest assignment before the reference" do
    receiver_at(source, 22, 12).should eq("Int32")
  end

  it "refuses a local assigned from a call it cannot find" do
    receiver_at(source, 24, 12).should eq("unknown (unresolved name: no `build` on Session)")
  end

  it "types an ivar from its evident assignments and ignores call results, like the compiler" do
    receiver_at(source, 25, 12).should eq("Store")
    receiver_at(source, 26, 12).should eq("Store | Nil")
  end
end

describe Heucristic::Resolve::Receiver, "call results" do
  source = <<-CR
    module Enumerable(T)
      def first : T
      end

      def flat_map(& : T -> _)
      end
    end

    class Array(T)
      include Enumerable(T)

      def uniq! : self
      end
    end

    class Channel(T)
      def receive : T
      end
    end

    class Builder
      def build : Array(String)
      end

      def run(names : Array(String), results : Channel(Array(Int32)?)) : Nil
        names.first.size
        names.uniq!.size
        results.receive.size
        build.size
        names.flat_map { |name| name }.size
        paths = names.flat_map { |name| name }.uniq!
        paths.size
      end
    end
    CR

  it "binds a type variable to the receiver's argument through an include" do
    receiver_of_size(source, "names.first.size").should eq("String")
  end

  it "resolves self to the receiver with its arguments" do
    receiver_of_size(source, "names.uniq!.size").should eq("Array(String)")
  end

  it "binds a type variable on the receiver's own type" do
    receiver_of_size(source, "results.receive.size").should eq("Array(Int32) | Nil")
  end

  it "types the result of an implicit self call from its return restriction" do
    receiver_of_size(source, "build.size").should eq("Array(String)")
  end

  it "names the def that lacks a return type" do
    receiver_of_size(source, "names.flat_map { |name| name }.size").should eq(
      "unknown (no annotation: Enumerable#flat_map has no return type restriction)"
    )
    receiver_of_size(source, "paths.size").should eq(
      "unknown (no annotation: Enumerable#flat_map has no return type restriction)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "argument bindings" do
  source = <<-CR
    class Array(T)
      def +(other : Array(U)) : Array(T | U) forall U
      end

      def zip(other : Array(U)) : Array(Tuple(T, U)) forall U
      end
    end

    class Box
      def pair(a : Array(String), b : Array(Int32), c : Int32?) : Nil
        (a + b).size
        a.zip(b).size
        wrap(c).size
      end

      def wrap(value : U?) : Array(U) forall U
      end
    end
    CR

  it "binds a def's free variable from the matching argument" do
    receiver_of_size(source, "(a + b).size").should eq("Array(String | Int32)")
    receiver_of_size(source, "a.zip(b).size").should eq("Array(Tuple(String, Int32))")
  end

  it "binds through a nilable restriction" do
    receiver_of_size(source, "wrap(c).size").should eq("Array(Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "overloads" do
  source = <<-CR
    module Math
      extend self

      def min(value1 : Float32, value2 : Float32) : Float32
      end

      def min(value1 : Float64, value2 : Float64) : Float64
      end

      def min(value1, value2)
      end
    end

    class Calc
      def run(a : Int32, b : Float64, c : Float64, d) : Nil
        Math.min(a, a).abs
        Math.min(b, c).abs
        Math.min(d, d).abs
      end
    end
    CR

  it "picks the overload whose restrictions admit the argument types" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(b, c).size").should eq("Float64")
  end

  it "refuses to guess when the argument types rule out every typed overload" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(a, a).size").should eq(
      "unknown (no annotation: Math#min has no return type restriction)"
    )
  end

  it "keeps every overload for an unknown argument and reports the ambiguity" do
    receiver_of_size(source.gsub("abs", "size"), "Math.min(d, d).size").should eq(
      "unknown (ambiguous: 3 overloads of `min` do not agree on a type)"
    )
  end

  it "does not pick the typed overload over an untyped one when the argument is unknown" do
    source = <<-CR
      module Math
        extend self

        def max(value1 : Float64, value2 : Float64) : Float64
        end

        def max(value1, value2)
        end
      end

      def go(d) : Nil
        Math.max(d, d).size
      end
      CR
    receiver_of_size(source, "Math.max(d, d).size").should eq(
      "unknown (ambiguous: 2 overloads of `max` do not agree on a type)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "block results" do
  source = <<-CR
    class String
      def size : Int32
      end
    end

    module Enumerable(T)
      def flat_map(& : T -> Array(U) | Iterator(U) | U) : Array(U) forall U
      end

      def sum(& : T -> U) : U forall U
      end

      def each(& : T ->) : Nil
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Dir
      def self.glob(pattern : String) : Array(String)
      end
    end

    class Shared(T)
      def lock(& : T -> U) : U forall U
      end
    end

    class Walker
      def run(roots : Array(String), shared : Shared(Tuple(String, Int32))) : Nil
        shared.lock { |name, count| name }.size
        roots.flat_map { |root| Dir.glob(root) }.size
        roots.flat_map { |root| root }.size
        roots.sum { |root| root.size }.size
        roots.flat_map { |root| unknown_call(root) }.size
      end
    end
    CR

  it "binds a free variable from the block result through the shaped union member" do
    receiver_of_size(source, "roots.flat_map { |root| Dir.glob(root) }.size").should eq(
      "Array(String)"
    )
  end

  it "binds a free variable from a bare block result" do
    receiver_of_size(source, "roots.flat_map { |root| root }.size").should eq("Array(String)")
    receiver_of_size(source, "roots.sum { |root| root.size }.size").should eq("Int32")
  end

  it "splats a yielded tuple across the block parameters (crystal run: String)" do
    receiver_of_size(source, "shared.lock { |name, count| name }.size").should eq("String")
  end

  it "leaves the variable free when the block result is unknown" do
    receiver_of_size(source, "roots.flat_map { |root| unknown_call(root) }.size").should eq(
      "Array(unknown (unresolved name: U = no `unknown_call` on Walker))"
    )
  end
end

describe Heucristic::Resolve::Receiver, "block parameters" do
  source = <<-CR
    module Enumerable(T)
      def each_with_index(offset = 0, & : T, Int32 ->) : Nil
      end

      def each(& : T ->) : Nil
      end

      def sort_by(&)
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Walker
      def run(names : Array(String)) : Nil
        names.each_with_index do |name, index|
          name.size
          index.size
          names.each { |inner| inner.size }
        end
        names.sort_by { |name| name.size }
      end
    end
    CR

  it "types block parameters from the yielding def's block restriction" do
    receiver_of_size(source, "name.size").should eq("String")
    receiver_of_size(source, "index.size").should eq("Int32")
  end

  it "resolves a nested block against its own call" do
    receiver_of_size(source, "inner.size").should eq("String")
  end

  it "says so when the def does not state what it yields" do
    receiver_of_size(source, "names.sort_by { |name| name.size }").should eq(
      "unknown (no annotation: Enumerable#sort_by never yields)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "constants" do
  source = <<-CR
    module System
      def self.cpu_count : Int32
      end
    end

    module Fibers
      WORKERS = System.cpu_count
      NAMES = [] of String
      LIMIT = compute
    end

    def go : Nil
      Fibers::WORKERS.size
      Fibers::NAMES.size
      Fibers::LIMIT.size
      Fibers.size
    end
    CR

  it "types a constant from its value expression through return restrictions" do
    receiver_of_size(source, "Fibers::WORKERS.size").should eq("Int32")
  end

  it "types a constant from an evident value" do
    receiver_of_size(source, "Fibers::NAMES.size").should eq("Array(String)")
  end

  it "reports a constant whose value it cannot type" do
    receiver_of_size(source, "Fibers::LIMIT.size").should eq(
      "unknown (unresolved name: no `compute` on Fibers.class)"
    )
  end

  it "treats a bare type name as its metaclass" do
    receiver_of_size(source, "Fibers.size").should eq("Fibers.class")
  end
end

describe Heucristic::Resolve::Receiver, "cycles" do
  it "terminates when a variable is reassigned through a block over itself" do
    source = <<-CR
      module Enumerable(T)
        def map(& : T -> U) : Array(U) forall U
        end
      end

      class Array(T)
        include Enumerable(T)
      end

      def go : Nil
        list = build
        list = list.map { |item| item }
        list.size
        other = 1
        other = other.to_s
        other.size
      end
      CR
    receiver_of_size(source, "list.size").should start_with("unknown")
    receiver_of_size(source, "other.size").should start_with("unknown")
  end
end

describe Heucristic::Resolve::Receiver, "delegate" do
  source = <<-CR
    class Environment
      def token : String
      end

      def organisation(id : Int32) : Int32
      end
    end

    class Config
      delegate :token, :organisation, to: current
      delegate missing, to: current

      def current : Environment
      end

      def run(config : Config) : Nil
        config.token.size
        config.organisation(1).size
        config.missing.size
      end
    end
    CR

  it "types a delegated call through the target's method" do
    receiver_of_size(source, "config.token.size").should eq("String")
    receiver_of_size(source, "config.organisation(1).size").should eq("Int32")
  end

  it "reports a delegated name the target lacks" do
    receiver_of_size(source, "config.missing.size").should eq(
      "unknown (unresolved name: no `missing` on Environment)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "extended class methods" do
  source = <<-CR
    module Digest
      module ClassMethods
        def hexdigest(data : String) : String
        end
      end

      class SHA256
        extend ClassMethods
      end
    end

    def go : Nil
      Digest::SHA256.hexdigest("x").size
    end
    CR

  it "types a class method reached through an extended module" do
    receiver_of_size(source, %(Digest::SHA256.hexdigest("x").size)).should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "inherited instance variables" do
  source = <<-CR
    class Model
      def id : Int32
      end
    end

    class Base(T)
      def initialize(@object : T) : Nil
      end
    end

    class Presenter < Base(Model)
      def render : Nil
        @object.size
        @object.id.size
      end
    end

    class Plain
      @count : Int32 = 0
    end

    class Child < Plain
      def go : Nil
        @count.size
      end
    end
    CR

  it "finds an ivar declared in a generic superclass with the type argument bound" do
    receiver_of_size(source, "@object.size").should eq("Model")
    receiver_of_size(source, "@object.id.size").should eq("Int32")
  end

  it "finds an ivar declared in a plain superclass" do
    receiver_of_size(source, "@count.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "unpacking indexable elements" do
  source = <<-CR
    module Enumerable(T)
      def each(& : T ->) : Nil
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    module Indexable(T)
      def [](index : Int) : T
      end
    end

    class Array(T)
      include Indexable(T)
    end

    class Entry
    end

    def go(pairs : Array(Array(Entry))) : Nil
      pairs.each { |(first, second)| first.size }
    end
    CR

  it "types a variable unpacked from an indexable element" do
    receiver_of_size(source, "pairs.each { |(first, second)| first.size }").should eq("Entry")
  end
end

describe Heucristic::Resolve::Receiver, "proc block arguments and splat parameters" do
  source = <<-CR
    class Object
      def try(& : self -> U) : U forall U
      end
    end

    struct Tuple(*T)
      def to_a : Array(Union(*T))
      end

      def [](index : Int) : Union(*T)
      end

      def clone : self
      end

      def reverse : Tuple(*T)
      end
    end

    class Runner
      def shout(text : String) : String
      end

      def loose(*things) : Nil
        things.size
      end

      def run(body : String?, *args : String) : Nil
        body.try(&->shout(String)).size
        args.to_a.size
        args[1].size
        args.reverse.size
        args.clone.size
        args.size
      end
    end
    CR

  it "treats a proc passed with & as a block" do
    receiver_of_size(source, "body.try(&->shout(String)).size").should eq("String")
  end

  it "types a splat parameter as a tuple of unknown size bounded by its restriction" do
    receiver_of_size(source, "args.size").should eq("Tuple(*String)")
  end

  it "types what a splat tuple answers whatever the call (crystal run: Array(String))" do
    receiver_of_size(source, "args.to_a.size").should eq("Array(String)")
    receiver_of_size(source, "args[1].size").should eq("String")
  end

  it "bounds an unrestricted splat's elements by nothing (crystal run: Tuple(Int32, String))" do
    receiver_of_size(source, "things.size").should start_with("Tuple(*unknown")
  end

  it "never turns a splat tuple into a fixed one (crystal run: Tuple(String, String))" do
    receiver_of_size(source, "args.reverse.size").should eq("Tuple(*String)")
    receiver_of_size(source, "args.clone.size").should eq("Tuple(*String)")
  end
end

describe Heucristic::Resolve::Receiver, "module instance variables" do
  source = <<-CR
    class Event
      def id : Int32
      end
    end

    module Notification
      module Base
        def id : Int32
          @event.id.size
        end
      end

      struct Kept
        include Base

        def initialize(@event : Event) : Nil
        end
      end

      struct Purged
        include Base

        def initialize(@event : Event) : Nil
        end
      end
    end
    CR

  it "types an ivar used in a module from the types that include it" do
    receiver_of_size(source, "@event.id.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "block bodies" do
  source = <<-CR
    module Enumerable(T)
      def map(& : T -> U) : Array(U) forall U
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    class Result(T)
      def unwrap_or(& : String -> U) : T | U forall U
      end
    end

    class Worker
      def lookup(name : String) : Int32?
      end

      def run(names : Array(String), result : Result(Int32)) : Nil
        names.map { |name| found = lookup(name); found ? found : 0 }.size
        result.unwrap_or { |error| return }.size
        names.map do |name|
          value = lookup(name)
          next 0 unless value

          value
        end.size
        (lookup("a") || 0).size
        (lookup("a") && "found").size
      end
    end
    CR

  it "types a block body through its own assignments and guards" do
    receiver_of_size(source, "found ? found : 0 }.size").should eq("Array(Int32)")
  end

  it "treats a block that returns as NoReturn" do
    receiver_of_size(source, "result.unwrap_or { |error| return }.size").should eq("Int32")
  end

  it "narrows a block local after a guard that exits with next" do
    receiver_of_size(source, "end.size").should eq("Array(Int32)")
  end

  it "types or and and expressions from their operands" do
    receiver_of_size(source, "(lookup(\"a\") || 0).size").should eq("Int32")
    receiver_of_size(source, "(lookup(\"a\") && \"found\").size").should eq("Nil | String")
  end
end

describe Heucristic::Resolve::Receiver, "proc types" do
  source = <<-CR
    struct Proc(*T, R)
      def call(*args : *T) : R
      end
    end

    class Runner
      def contain(& : -> T) : T | Exception forall T
      end

      def launch(block : Int32 ->) : Nil
        contain { block.call(1) }.size
      end

      def fetch(key : String, & : -> T) : T forall T
      end

      def fetch(*keys : String, &block : -> T) : T forall T
        fetch("k", &block).size
      end

      def typed(callback : String -> Int32) : Nil
        callback.size
        callback.call("a").size
      end
    end
    CR

  it "resolves a proc restriction to Proc with its output last" do
    receiver_of_size(source, "callback.size").should eq("Proc(String, Int32)")
    receiver_of_size(source, "callback.call(\"a\").size").should eq("Int32")
  end

  it "binds a free variable from a block that calls a proc" do
    receiver_of_size(source, "contain { block.call(1) }.size").should eq("Nil | Exception")
  end

  it "binds a free variable from a forwarded block parameter" do
    receiver_of_size(source, "fetch(\"k\", &block).size").should eq("T")
  end
end

describe Heucristic::Resolve::Receiver, "free variables from defaults and metaclasses" do
  source = <<-CR
    module Enumerable(T)
      def find(if_none : U = nil, & : T ->) : T | U forall U
      end

      def select(type : U.class) : Array(U) forall U
      end
    end

    class Array(T)
      include Enumerable(T)
    end

    record Circle
    record Square
    alias Shape = Circle | Square

    module Pool(T, R)
      def self.run(items : Array(T), & : T -> R) : Array(R)
      end
    end

    class User
      def go(names : Array(String), shapes : Array(Circle | Square | String)) : Nil
        names.find { |name| name }.size
        shapes.select(Circle).size
        shapes.select(Shape).size
        Pool.run(names) { |name| 1 }.size
      end
    end
    CR

  it "binds a free variable from the default of an omitted parameter" do
    receiver_of_size(source, "names.find { |name| name }.size").should eq("String | Nil")
  end

  it "binds a free variable from a metaclass argument" do
    receiver_of_size(source, "shapes.select(Circle).size").should eq("Array(Circle)")
  end

  it "binds a free variable from a union alias used as a metaclass argument" do
    receiver_of_size(source, "shapes.select(Shape).size").should eq("Array(Circle | Square)")
  end

  it "binds the type variables of a generic module from a class method call" do
    receiver_of_size(source, "Pool.run(names) { |name| 1 }.size").should eq("Array(Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "type variables" do
  source = <<-CR
    class Base(T, E)
    end

    class Result(T) < Base(T, String)
      def self.from(raw : String) : self
        parse(raw).size
      end

      private def self.parse(raw : String) : T | E
      end

      def value : T
      end

      def show : Nil
        value.size
      end
    end

    class Consumer
      def use(result : Result(Int32)) : Nil
        result.value.size
      end
    end
    CR

  it "resolves a type's own type variable to itself inside its body" do
    receiver_of_size(source, "parse(raw).size").should eq("T | String")
  end

  it "keeps a call result that is the owner's type variable as the variable" do
    receiver_of_size(source, "value.size").should eq("T")
  end

  it "binds the type variable when the receiver is instantiated" do
    receiver_of_size(source, "result.value.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "narrowing an inline assignment" do
  source = <<-CR
    class Owner
      def owner : String | Int32
      end

      def go : Nil
        if (name = owner).is_a?(String)
          name.size
        end
      end
    end
    CR

  it "narrows a variable assigned inside an is_a? condition" do
    receiver_of_size(source, "name.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "or-assignment and cyclic branches" do
  source = <<-CR
    class Array(T)
      def dup : self
      end
    end

    class Loader
      def load : Array(String)?
      end

      def fallback : Array(String)
      end

      def run(shifts : Array(String)?) : Nil
        shifts ||= fallback
        shifts.size
        bindings = Array(Int32).new
        inherited = shifts ? fallback : bindings
        bindings = inherited.dup
        bindings.size
      end
    end
    CR

  it "drops Nil from a variable after an or-assignment" do
    receiver_of_size(source, "shifts.size").should eq("Array(String)")
  end

  it "feeds a cyclic branch the type gathered so far" do
    receiver_of_size(source, "bindings.size").should eq("Array(String) | Array(Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "exits through NoReturn methods" do
  source = <<-CR
    record Target
    record Problem

    class Sync
      def parse : Target | Problem
      end

      def fail_with(message : String) : NoReturn
      end

      def take(value : Int32) : String
      end

      def run(mixed : Int32 | String) : Nil
        target = parse
        if target.is_a?(Problem)
          fail_with("bad")
        end
        target.size
        take(mixed).size
      end
    end
    CR

  it "narrows past a guard that calls a NoReturn method" do
    receiver_of_size(source, "target.size").should eq("Target")
  end

  it "falls back to arity matches when no overload admits the argument types" do
    receiver_of_size(source, "take(mixed).size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "lib declarations" do
  source = <<-CR
    lib LibWatch
      type Handle = Void*

      struct Event
        mask : UInt32
        name : LibC::Char*
      end

      fun read = watch_read(handle : Handle, buffer : Void*) : Event
    end

    class Watcher
      def poll(handle : LibWatch::Handle, event : LibWatch::Event) : Nil
        LibWatch.read(handle, nil).size
        event.mask.size
      end
    end
    CR

  it "types a fun call from its return type" do
    receiver_of_size(source, "LibWatch.read(handle, nil).size").should eq("LibWatch::Event")
  end

  it "types a C struct field from its declaration" do
    receiver_of_size(source, "event.mask.size").should eq("UInt32")
  end
end

describe Heucristic::Resolve::Receiver, "extend self and widened reassignment" do
  source = <<-CR
    class String
      def [](range : Range) : String
      end
    end

    module Parsing
      extend self

      def parse(source : String) : Int32
      end
    end

    class Directory
    end

    class Walker
      def entries : Array(String)
      end

      def run(base : Directory?, text : String) : Nil
        Parsing.parse(text).size
        stack = nil
        entries.each do |entry|
          stack ||= Array(String).new
          stack << entry
        end
        return if stack.nil?

        stack.size
        base_directory = base if base
        base_directory.size
        text[(1)..].size
      end
    end
    CR

  it "finds module methods exposed through extend self" do
    receiver_of_size(source, "Parsing.parse(text).size").should eq("Int32")
  end

  it "widens a variable reassigned inside a block before a guard" do
    receiver_of_size(source, "stack.size").should eq("Array(String)")
  end

  it "types a conditional assignment as the value or nil" do
    receiver_of_size(source, "base_directory.size").should eq("Directory | Nil")
  end

  it "types a range literal from its bounds" do
    receiver_of_size(source, "text[(1)..].size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "file-private declarations" do
  files = {
    "a.cr" => <<-CR,
      class Foo
      end

      private alias Sync = Foo

      class Local
        def go : Nil
          Sync.new.size
        end
      end
      CR
    "b.cr" => <<-CR,
      module Sync
        class Mutex
        end
      end

      class User
        def go : Nil
          Sync::Mutex.new.size
        end
      end
      CR
  }

  it "resolves a file-private alias inside its own file" do
    receiver_across(files, "a.cr", "Sync.new.size").should eq("Foo")
  end

  it "keeps a file-private alias out of other files" do
    receiver_across(files, "b.cr", "Sync::Mutex.new.size").should eq("Sync::Mutex")
  end
end

describe Heucristic::Resolve::Receiver, "a nilable alias union bound through a block result" do
  source = <<-CR
    record First, size : Int32
    record Second, size : Int32
    alias Either = First | Second

    def pick : Either?
    end

    class Box(T)
      def item : T
      end

      def keep(& : T -> U?) : Box(U) forall U
      end
    end

    def run(box : Box(Int32)) : Nil
      box.keep { pick }.item.size
    end
    CR

  it "drops Nil from the bound variable when the block returns an alias union or nil" do
    receiver_of_size(source, "box.keep { pick }.item.size").should eq("First | Second")
  end
end

describe Heucristic::Resolve::Receiver, "file-private types shadowing same-named types" do
  files = {
    "a.cr" => <<-CR,
      private class Foo
        def value : Int32
          1
        end
      end

      class Child < Foo
      end

      class UsesA
        def go : Nil
          Foo.new.value.size
          Child.new.value.size
        end
      end
      CR
    "b.cr" => <<-CR,
      class Foo
        def value : String
          "x"
        end
      end

      class UsesB
        def go : Nil
          Foo.new.value.size
        end
      end
      CR
    "c.cr" => <<-CR,
      private class Foo
        def value : Symbol
          :c
        end
      end

      class UsesC
        def go : Nil
          Foo.new.value.size
        end
      end
      CR
  }

  it "resolves a name to the file-private type of the file that mentions it" do
    receiver_across(files, "a.cr", "Foo.new.value.size").should eq("Int32")
  end

  it "resolves a name to the public type when the file declares no private one" do
    receiver_across(files, "b.cr", "Foo.new.value.size").should eq("String")
  end

  it "keeps same-named private types of different files apart" do
    receiver_across(files, "c.cr", "Foo.new.value.size").should eq("Symbol")
  end

  it "inherits from the private type the declaring file names" do
    receiver_across(files, "a.cr", "Child.new.value.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "instance variables assigned from calls" do
  source = <<-CR
    struct Instant
    end

    module Clock
      def self.instant : Instant
      end
    end

    class Reporter
      def initialize : Nil
        @started = Clock.instant
        @computed = build
      end

      def build : Int32
      end

      def go : Nil
        @started.size
        @computed.size
      end
    end
    CR

  it "guesses the type from an annotated class method call, like the compiler" do
    receiver_of_size(source, "@started.size").should eq("Instant")
  end

  it "explains an instance variable assigned only from an untyped expression" do
    receiver_of_size(source, "@computed.size").should eq(
      "unknown (no annotation: @computed is only assigned build; declare its type)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "tuple packs and zip" do
  source = <<-CR
    module Enumerable(T)
      def zip(*others : Indexable | Iterable | Iterator) : Nil
      end

      def each(& : T ->) : Nil
      end
    end

    module Indexable(T)
      include Enumerable(T)
    end

    class Array(T)
      include Indexable(T)
    end

    struct Tuple
      include Indexable(Union(*T))

      def first
      end

      def first?
      end

      def map(& : Union(*T) -> U) : Array(U) forall U
      end
    end

    class Mixer
      def split(names : Array(String)) : {Array(String), Array(String)}
      end

      def run(pair : Tuple(Int32, String), names : Array(String), counts : Array(Int32)) : Nil
        pair.first.size
        pair.first?.size
        pair.map { |member| "x" }.size
        pair.each { |member| member.size }
        names.zip(counts).size
        split(names).size
      end
    end
    CR

  it "types the first element of a tuple" do
    receiver_of_size(source, "pair.first.size").should eq("Int32")
    receiver_of_size(source, "pair.first?.size").should eq("Int32 | Nil")
  end

  it "maps a tuple to a tuple of the block result" do
    receiver_of_size(source, "pair.map { |member| \"x\" }.size").should eq("Tuple(String, String)")
  end

  it "yields the union of the pack from a tuple's Indexable" do
    receiver_of_size(source, "member.size }").should eq("Int32 | String")
  end

  it "types zip as an array of tuples" do
    receiver_of_size(source, "names.zip(counts).size").should eq("Array(Tuple(String, Int32))")
  end

  it "reads a tuple literal restriction as Tuple" do
    receiver_of_size(source, "split(names).size").should eq("Tuple(Array(String), Array(String))")
  end
end

describe Heucristic::Resolve::Receiver, "parenthesised case subjects" do
  source = <<-CR
    record Problem
    record Metadata

    class Disk
      def observe : Metadata | Problem | Nil
      end

      def run : Nil
        case (found = observe)
        in Nil then nil
        in Problem then found.size
        in Metadata then found.size
        end
      end
    end
    CR

  it "narrows the assigned variable inside each in branch" do
    receiver_of_size(source, "in Problem then found.size").should eq("Problem")
    receiver_of_size(source, "in Metadata then found.size").should eq("Metadata")
  end
end

describe Heucristic::Resolve::Receiver, "default constructors" do
  source = <<-CR
    abstract struct Credential
    end

    struct GitHubCLI < Credential
    end

    struct Grouping
      def self.build : Grouping
        grouping = new
        grouping.size
        GitHubCLI.new.size
      end
    end
    CR

  it "constructs a type without initialize through the implicit new" do
    receiver_of_size(source, "grouping.size").should eq("Grouping")
    receiver_of_size(source, "GitHubCLI.new.size").should eq("GitHubCLI")
  end
end

describe Heucristic::Resolve::Receiver, "same-named locals in sibling blocks" do
  source = <<-CR
    module Enumerable(T)
      def each(& : T ->) : Nil
      end

      def map(& : T -> U) : Array(U) forall U
      end
    end

    class Array(T)
      include Enumerable(T)

      def compact : Array(T)
      end
    end

    class Purger
      def check(name : String) : String?
      end

      def run(names : Array(String)) : Nil
        failures = names.map do |name|
          error = check(name)
          {name, error} if error
        end.compact
        failures.each do |name, error|
          error.size
        end
      end
    end
    CR

  it "does not confuse a block local with a same-named parameter of another block" do
    receiver_of_size(source, "error.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "multiple assignment" do
  source = <<-CR
    module Enumerable(T)
      def partition(& : T ->) : {Array(T), Array(T)}
      end
    end

    class Array(T)
      include Enumerable(T)

      def [](index : Int) : T
      end
    end

    class Splitter
      def run(pair : Tuple(Int32, String), names : Array(String)) : Nil
        left, right = pair
        left.size
        right.size
        pair.size
        pair[1].size
        ongoing, finished = names.partition { |name| name }
        finished.size
        first, second = names
        second.size
        one, two = 1, "two"
        two.size
      end
    end
    CR

  it "types each target of a tuple unpacking" do
    receiver_of_size(source, "left.size").should eq("Int32")
    receiver_of_size(source, "right.size").should eq("String")
    receiver_of_size(source, "pair[1].size").should eq("String")
  end

  it "types targets unpacked from a call result and from an array" do
    receiver_of_size(source, "finished.size").should eq("Array(String)")
    receiver_of_size(source, "second.size").should eq("String")
  end

  it "types targets of a one-to-one multiple assignment" do
    receiver_of_size(source, "two.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "Class methods and top-level defs" do
  source = <<-CR
    class Object
      def class
      end
    end

    class Class
      def name : String
      end
    end

    class Fiber
    end

    def spawn(*, name : String? = nil, same_thread = false, &block) : Fiber
    end

    class Worker
      def self.run : Nil
        spawn { 1 }.size
      end

      def report(error : Exception) : Nil
        error.class.name.size
        spawn { 1 }.size
      end
    end
    CR

  it "finds Class instance methods on a metaclass receiver" do
    receiver_of_size(source, "error.class.name.size").should eq("String")
  end

  it "falls back to top-level defs for receiverless calls" do
    receiver_of_size(source, "spawn { 1 }.size").should eq("Fiber")
  end
end

describe Heucristic::Resolve::Receiver, "case, begin and assignment expressions" do
  source = <<-CR
    class Int32
      def +(other : Int32) : Int32
      end
    end

    class Hash(K, V)
      def [](key : K) : V
      end

      def []=(key : K, value : V) : V
      end
    end

    enum Kind
      Fast
      Slow
    end

    class Picker
      def kind : Kind
      end

      def risky : String
      end

      def run(table : Hash(String, Array(Int32)), cache : Array(Int32)?, count : Int32) : Nil
        label = case kind
                in .fast? then "f"
                in .slow? then "s"
                end
        label.size
        loose = case count
                when 1 then "one"
                end
        loose.size
        guarded = begin
          risky
        rescue
          1
        end
        guarded.size
        (table["k"] ||= Array(Int32).new).size
        (cache ||= Array(Int32).new).size
        (count += 1).size
        (read = risky).size
      end
    end
    CR

  it "types an exhaustive case as the union of its branches" do
    receiver_of_size(source, "label.size").should eq("String")
  end

  it "adds Nil to a non-exhaustive case without else" do
    receiver_of_size(source, "loose.size").should eq("String | Nil")
  end

  it "types begin/rescue as the union of the body and handlers" do
    receiver_of_size(source, "guarded.size").should eq("String | Int32")
  end

  it "types or-assignment, operator assignment and assignment expressions" do
    receiver_of_size(source, "(table[\"k\"] ||= Array(Int32).new).size").should eq("Array(Int32)")
    receiver_of_size(source, "(cache ||= Array(Int32).new).size").should eq("Array(Int32)")
    receiver_of_size(source, "(count += 1).size").should eq("Int32")
    receiver_of_size(source, "(read = risky).size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "yield expressions" do
  source = <<-CR
    class Store
      def fetch(key : String, & : String -> Int32) : Nil
        (yield key).size
      end

      def wrap(& : -> U) : Nil forall U
        (yield).size
      end

      def silent(&) : Nil
        (yield).size
      end
    end
    CR

  it "types yield from the block's declared output" do
    receiver_of_size(source, "(yield key).size").should eq("Int32")
  end

  it "keeps a free variable output as the variable" do
    receiver_of_size(source, "(yield).size").should eq("U")
  end

  it "explains a yield whose block has no declared output" do
    line = source.lines.index!(&.includes?("def silent")) + 2
    receiver_at(source, line, 13).should eq(
      "unknown (no annotation: the block of silent has no declared result type)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "hash literals" do
  source = <<-CR
    class Hash(K, V)
    end

    module HTTP
      class Headers
      end
    end

    class Client
      def initialize(@token : String) : Nil
        @headers = HTTP::Headers{"Authorization" => "Bearer"}
      end

      def run(user_id : Int32) : Nil
        {"time" => "now", "user" => user_id}.size
        @headers.size
      end
    end
    CR

  it "types a hash literal from the union of its keys and values" do
    receiver_of_size(source, "{\"time\" => \"now\", \"user\" => user_id}.size").should eq(
      "Hash(String, String | Int32)"
    )
  end

  it "types a hash-like literal with a receiver type as that type" do
    receiver_of_size(source, "@headers.size").should eq("HTTP::Headers")
  end
end

describe Heucristic::Resolve::Receiver, "class variables" do
  source = <<-CR
    class Registry
      @@contexts : Array(String)?
      @@count = 0

      def run : Nil
        @@contexts.size
        @@count.size
      end
    end
    CR

  it "types a declared class variable" do
    receiver_of_size(source, "@@contexts.size").should eq("Array(String) | Nil")
  end

  it "types a class variable from its evident assignment" do
    receiver_of_size(source, "@@count.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "case exits and either is_a?" do
  source = <<-CR
    record Problem
    record Metadata

    class Disk
      def observe : Metadata | Problem | Nil
      end

      def run(node : Int32 | String | Nil) : Nil
        case (found = observe)
        in Nil then return
        in Problem then return
        in Metadata
        end
        found.size
        return unless node.is_a?(Int32) || node.is_a?(String)

        node.size
      end
    end
    CR

  it "narrows past an exhaustive case whose other branches exit" do
    receiver_of_size(source, "found.size").should eq("Metadata")
  end

  it "narrows through a positive or of is_a? checks" do
    receiver_of_size(source, "node.size").should eq("Int32 | String")
  end
end

describe Heucristic::Resolve::Receiver, "sizeof and proc literals" do
  source = <<-CR
    class Disk
      def initialize : Nil
        @supply = -> : String { "x" }
      end

      def run : Nil
        sizeof(Int32).size
        @supply.size
      end
    end
    CR

  it "types sizeof as Int32 and a proc literal from its signature" do
    receiver_of_size(source, "sizeof(Int32).size").should eq("Int32")
    receiver_of_size(source, "@supply.size").should eq("Proc(String)")
  end
end

describe Heucristic::Resolve::Receiver, "variables inside macro regions" do
  source = <<-CR
    class Configuration
      def load(display : String) : Nil
        {% if flag?(:never_set) %}
          display.upcase
        {% else %}
          display.size
        {% end %}
      end
    end
    CR

  it "keeps method parameters as variables when a macro region is re-parsed" do
    receiver_of_size(source, "display.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "assignments typed at their own position" do
  source = <<-CR
    class Int32
      def abs : Int32
      end
    end

    class Reporter
      def progress : Int32?
      end

      def mebibytes(bytes : Int32) : String
      end

      def throughput : Nil
        sent = progress
        return if sent.nil?

        sent_bytes = sent.abs
        sent = mebibytes(sent_bytes)
        sent_bytes.size
        sent.size
      end
    end
    CR

  it "types a value from the state at the assignment, not at the use" do
    receiver_of_size(source, "sent_bytes.size").should eq("Int32")
    receiver_of_size(source, "sent.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "self-referential assignments" do
  source = <<-CR
    class Array(T)
      def +(other : Array(U)) : Array(T | U) forall U
      end

      def each(& : T ->) : Nil
      end
    end

    class Int32
      def >>(count : Int32) : Int32
      end
    end

    record Change

    class Session
      def entries : Array(Array(Change))
      end

      def merge : Nil
        changes = Array(Change).new
        entries.each do |entry|
          changes = changes + entry
        end
        changes.size
        a = 1
        while a > 0
          a = a >> 8
        end
        a.size
      end
    end
    CR

  it "types a variable rebuilt from itself inside a block" do
    receiver_of_size(source, "changes.size").should eq("Array(Change)")
  end

  it "types a variable shifted from itself inside a loop" do
    receiver_of_size(source, "a.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "cyclic widening" do
  source = <<-CR
    class Nester
      def run : Nil
        nested = 1
        while true
          nested = [nested]
        end
        nested.size
      end
    end
    CR

  it "stops and explains when a variable widens on every pass" do
    receiver_of_size(source, "nested.size").should eq(
      "unknown (cycle: nested widens on every pass (Int32 then Array(Int32)); declare its type)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "guards inside conditions and branch fallthrough" do
  source = <<-CR
    record EndOfStream

    class String
      def lchop?(prefix : String) : String?
      end

      def <=(other : String) : Bool
      end
    end

    class Int32
      def <=(other : Int32) : Bool
      end
    end

    class Framing
      def read_line : String | EndOfStream
      end

      def lookup : Array(String) | EndOfStream
      end

      def read : Nil
        loop do
          line = read_line
          return line unless line.is_a?(String)

          next unless (value = line.lchop?("Content-Length:"))
          value.size
        end
        found = lookup
        if found.is_a?(EndOfStream)
          return unless read_line
          found = Array(String).new
        end
        found.size
        (1 <= 2 <= 3).size
      end
    end
    CR

  it "narrows a variable used inside a guard's own condition" do
    receiver_of_size(source, "value.size").should eq("String")
  end

  it "narrows away the branch condition when a branch ends by reassigning" do
    receiver_of_size(source, "found.size").should eq("Array(String)")
  end

  it "types a chained comparison as Bool" do
    receiver_of_size(source, "(1 <= 2 <= 3).size").should eq("Bool")
  end
end

describe Heucristic::Resolve::Receiver, "accessor defaults and void funs" do
  source = <<-CR
    class Progress
    end

    lib LibWatch
      fun stop = watch_stop(handle : Void*)
    end

    class Endpoint
      getter sent = Progress.new

      def run : Nil
        @sent.size
        LibWatch.stop(nil).size
      end
    end
    CR

  it "declares the ivar behind an accessor with a default value" do
    receiver_of_size(source, "@sent.size").should eq("Progress")
  end

  it "types a fun without a return type as Nil" do
    receiver_of_size(source, "LibWatch.stop(nil).size").should eq("Nil")
  end
end

describe Heucristic::Resolve::Receiver, "loops and nested reassignment positions" do
  source = <<-CR
    record Organisation
    record Failure

    class Array(T)
      def dup : self
      end
    end

    class Login
      def prompt : Organisation?
      end

      def bindings_of : Array(String) | Failure
      end

      def run(organisation : Organisation?, metaclass : Bool) : Nil
        while organisation.nil?
          organisation = prompt
        end
        organisation.size
        bindings = Array(Int32).new
        unless metaclass
          inherited = bindings_of
          if inherited.is_a?(Failure)
            return unless metaclass
            inherited = Array(String).new
          end
          bindings = inherited.dup
        end
        bindings.size
      end
    end
    CR

  it "narrows past a while loop by its exit condition" do
    receiver_of_size(source, "organisation.size").should eq("Organisation")
  end

  it "types a nested reassignment at its own position" do
    receiver_of_size(source, "bindings.size").should eq("Array(String) | Array(Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "module methods through includers" do
  source = <<-CR
    module Serializable
    end

    module ClockIn
      def clock_in_time : Nil
        at.size
      end
    end

    struct Command
      include ClockIn
      include Serializable

      getter at : String?

      def to_json : String
      end
    end

    class Request
      def put(body : Serializable) : Nil
        body.to_json.size
      end
    end
    CR

  it "resolves a receiverless call inside a module through the types that include it" do
    receiver_of_size(source, "at.size").should eq("String | Nil")
  end

  it "resolves a call on a module-typed receiver through its includers" do
    receiver_of_size(source, "body.to_json.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "top-level scripts" do
  source = <<-CR
    class Exception
    end

    def helper : Int32
    end

    count = helper
    count.size
    begin
      helper
    rescue ex
      ex.size
    end
    CR

  it "resolves top-level defs and variables outside any type" do
    receiver_of_size(source, "count.size").should eq("Int32")
    receiver_of_size(source, "ex.size").should eq("Exception")
  end

  it "keeps a top-level def apart from a class named Program (crystal run: Int32, String)" do
    program = <<-CR
      class Program
        def run : String
          "x"
        end
      end

      def run : Int32
        1
      end

      run.size
      Program.new.run.size
      CR
    receiver_of_size(program, "run.size").should eq("Int32")
    receiver_of_size(program, "Program.new.run.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "metaclasses of type variables" do
  source = <<-CR
    class Object
      def self.from_json(raw : String) : self
      end
    end

    class Decoder
      def decode(type : T.class, raw : String) : T forall T
        type.size
        type.from_json(raw).size
        type.new.size
      end
    end

    class Box(T)
      def build : Nil
        T.new.size
        T.other.size
      end
    end
    CR

  it "types a type variable metaclass parameter" do
    receiver_of_size(source, "type.size").should eq("T.class")
  end

  it "binds self to the type variable for class methods called on it" do
    receiver_of_size(source, "type.from_json(raw).size").should eq("T")
    receiver_of_size(source, "type.new.size").should eq("T")
    receiver_of_size(source, "T.new.size").should eq("T")
  end

  it "explains an unknown class method on a type variable" do
    receiver_of_size(source, "T.other.size").should eq(
      "unknown (free variable: T is a type variable; `other` depends on its instantiation)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "assignments inside conditions and case exclusion" do
  source = <<-CR
    class Definition
      def args : Array(String)
      end
    end

    enum Kind
      Success
      Info

      def success? : Bool
      end
    end

    module Named
      def label : String
        name.size
      end
    end

    struct Person
      include Named

      def name : String
      end
    end

    struct Pet
      include Named

      def name : String?
      end
    end

    class Walker
      def definition : Definition?
      end

      def run(kind : Kind?) : Nil
        current = definition
        if current && (arguments = current.args)
          arguments.size
        end
        case kind
        in Nil then nil
        in .success? then kind.size
        in .info? then nil
        end
      end
    end
    CR

  it "narrows the receiver of an assignment made inside an and condition" do
    receiver_of_size(source, "arguments.size").should eq("Array(String)")
  end

  it "excludes the types of earlier case branches inside a later branch" do
    receiver_of_size(source, "in .success? then kind.size").should eq("Kind")
  end

  it "unions module method results across includers that disagree" do
    receiver_of_size(source, "name.size").should eq("String | Nil")
  end
end

describe Heucristic::Resolve::Receiver, "branch joins" do
  source = <<-CR
    record Organisation

    struct Site
      NONE = new

      def initialize : Nil
      end
    end

    class Login
      def prompt : Organisation?
      end

      def run(organisations : Array(Organisation), organisation : Organisation?) : Nil
        unless organisation
          while organisation.nil?
            organisation = prompt
          end
        end
        organisation.size
        Site::NONE.size
        (Organisation | Login).size
        maybe = prompt
        maybe.try(&.size)
      end
    end
    CR

  it "joins the branches of an unless statement, including a loop inside it" do
    receiver_of_size(source, "organisation.size").should eq("Organisation")
  end

  it "resolves new in a type body as a class method" do
    receiver_of_size(source, "Site::NONE.size").should eq("Site")
  end

  it "types a union of metaclasses" do
    receiver_of_size(source, "(Organisation | Login).size").should eq(
      "Organisation.class | Login.class"
    )
  end
end

describe Heucristic::Resolve::Receiver, "loop and with-yield blocks" do
  it "types loop by its break values and as NoReturn without one" do
    source = <<-CR
      def loop(&)
      end

      first = loop do
        break 1
      end
      first
      second = loop do
        break
      end
      second
      third = loop do
        puts "x"
      end
      third
      CR
    receiver_at(source, 7, 1).should eq("Int32")
    receiver_at(source, 11, 1).should eq("Nil")
    receiver_at(source, 15, 1).should eq("NoReturn")
  end

  it "resolves receiverless calls inside a with-yield block against the yielded scope" do
    source = <<-CR
      class Builder
        def add(item : String) : Nil
        end
      end

      def build(& : ->) : Nil
        builder = Builder.new
        with builder yield
      end

      def outside : Nil
      end

      build do
        add("x")
        outside
      end
      CR
    receiver_at(source, 15, 3).should eq("Builder")
    receiver_at(source, 16, 3).should eq("top-level")
  end
end

describe Heucristic::Resolve::Receiver, "select" do
  it "types a select by its branch bodies and the received value by the channel" do
    source = <<-CR
      class Channel(T)
        def receive : T
        end
      end

      channel = Channel(Int32).new
      picked = select
      when number = channel.receive
        number
      when timeout(1.second)
        "late"
      end
      picked
      CR
    receiver_at(source, 9, 3).should eq("Int32")
    receiver_at(source, 13, 1).should eq("Int32 | String")
  end
end

describe Heucristic::Resolve::Receiver, "named tuples" do
  it "types named tuple literals, labelled annotations and symbol access ([:age]? is Int32)" do
    source = <<-CR
      struct NamedTuple
        def [](key : Symbol)
        end

        def []?(key : Symbol)
        end
      end

      person = {name: "Ann", age: 3}
      person
      n = person[:name]
      n
      a = person[:age]?
      a
      def describe(who : NamedTuple(name: String, age: Int32)) : Nil
        who
      end
      CR
    receiver_at(source, 10, 1).should eq("NamedTuple(name: String, age: Int32)")
    receiver_at(source, 12, 1).should eq("String")
    receiver_at(source, 14, 1).should eq("Int32")
    receiver_at(source, 16, 3).should eq("NamedTuple(name: String, age: Int32)")
  end
end

describe Heucristic::Resolve::Receiver, "type variables" do
  it "narrows a type variable by is_a? and case and keeps it across a non-assigning branch" do
    source = <<-CR
      def f(value : T) : Nil forall T
        if value.is_a?(String)
          value
        end
        case value
        in Int32 then value
        end
        value
      end
      CR
    receiver_at(source, 3, 5).should eq("String")
    receiver_at(source, 6, 18).should eq("Int32")
    receiver_at(source, 8, 3).should eq("T")
  end
end

private def marked(source : String, marker : String, column : Int32) : String
  line = source.lines.index!(&.includes?(marker)) + 1
  receiver_at(source, line, column)
end

describe Heucristic::Resolve::Receiver, "lessons from lavinmq" do
  it "keeps a block-local variable apart from same-named variables in sibling blocks" do
    source = <<-CR
      class Channel(T)
        def close : Nil
        end
      end

      def it(name : String, &) : Nil
        yield
      end

      it "a" do
        msgs = [1]
        msgs.size
      end
      it "b" do
        msgs = Channel(String).new
        msgs # HERE
      end
      CR
    marked(source, "msgs # HERE", 3).should eq("Channel(String)")
  end

  it "destructures a single yielded tuple across block parameters" do
    source = <<-CR
      def pair(& : ->) : Nil
        yield({1, "a"})
      end

      pair do |number, word|
        word # HERE
      end
      CR
    marked(source, "word # HERE", 3).should eq("String")
  end

  it "widens a call with a block by its break values" do
    source = <<-CR
      struct Int32
        def times(&block : self ->) : Nil
        end
      end

      found = 3.times do |i|
        break "x" if i == 1
      end
      found # HERE
      CR
    marked(source, "found # HERE", 1).should eq("Nil | String")
  end

  it "treats a begin whose rescues raise as a definite assignment" do
    source = <<-CR
      class Regex
      end

      def build : Regex
      end

      def go : Nil
        begin
          regex = build
        rescue ArgumentError
          raise "bad"
        end
        regex # HERE
      end
      CR
    marked(source, "regex # HERE", 3).should eq("Regex")
  end

  it "binds a rescue variable afresh even when the name was assigned earlier" do
    source = <<-CR
      class Boom < Exception
      end

      def exchange? : String?
      end

      def go(flag : Bool) : Nil
        if flag
          puts "a"
        elsif e = exchange?
          puts e
        end
        begin
          puts "x"
        rescue e : Boom
          e # HERE
        end
      end
      CR
    marked(source, "e # HERE", 5).should eq("Boom")
  end

  it "narrows an impossible branch to NoReturn" do
    source = <<-CR
      def pick : String | Int32
      end

      value = pick
      case value
      in Symbol then value # HERE
      in String, Int32 then value
      end
      CR
    marked(source, "value # HERE", 20).should eq("NoReturn")
  end

  it "types an enum member path and the implicit members of a flags enum" do
    source = <<-CR
      class Exchange
        enum PublishResult
          Routed
        end

        @[Flags]
        enum Options
          Durable
        end
      end

      result = Exchange::PublishResult::Routed
      result # HERE
      none = Exchange::Options::None
      none # NONE
      CR
    marked(source, "result # HERE", 1).should eq("Exchange::PublishResult")
    marked(source, "none # NONE", 1).should eq("Exchange::Options")
  end

  it "declares a variable from an uninitialized statement" do
    source = <<-CR
      lib LibC
        struct RUsage
          ru_maxrss : Int64
        end
      end

      usage = uninitialized LibC::RUsage
      usage # HERE
      CR
    marked(source, "usage # HERE", 1).should eq("LibC::RUsage")
  end
end

describe Heucristic::Resolve::Receiver, "Proc.new" do
  it "types the block parameters from the proc's inputs and returns the proc" do
    source = <<-CR
      struct Proc
        def self.new(&block : self)
        end
      end

      class Opcode
      end

      alias Instruction = Proc(Opcode, Nil)

      def skip : Instruction
        made = Instruction.new do |opcode|
          opcode # HERE
        end
        made # MADE
      end
      CR
    marked(source, "opcode # HERE", 5).should eq("Opcode")
    marked(source, "made # MADE", 3).should eq("Proc(Opcode, Nil)")
  end
end

describe Heucristic::Resolve::Receiver, "untyped readers of instance vars" do
  source = <<-CR
    class Store
    end

    class Box(T)
      getter value

      def initialize(@value : T)
      end
    end

    class Server
      getter store, name
      property? ready

      def initialize(@name : String, @ready = false)
        @store = Store.new
      end

      def title
        @name
      end

      getter shovels
      @shovels : Store?

      def shovels
        @shovels.not_nil!
      end

      def run(box : Box(Store)) : Nil
        store.size
        name.size
        ready?.size
        title.size
        shovels.size
        box.value.size
      end
    end
    CR

  it "types an untyped getter from an evident assignment to its ivar" do
    receiver_of_size(source, "store.size").should eq("Store")
  end

  it "types an untyped getter from an initialize parameter restriction" do
    receiver_of_size(source, "name.size").should eq("String")
  end

  it "types an untyped query property from its ivar's default" do
    receiver_of_size(source, "ready?.size").should eq("Bool")
  end

  it "types a def whose whole body reads an ivar" do
    receiver_of_size(source, "title.size").should eq("String")
  end

  it "lets a later def in the same file redefine an accessor" do
    receiver_of_size(source, "shovels.size").should contain("Server#shovels has no return type")
  end

  it "binds a generic owner's type variable through the receiver" do
    receiver_of_size(source, "box.value.size").should eq("Store")
  end
end

describe Heucristic::Resolve::Receiver, "Object methods on module-typed values" do
  source = <<-CR
    class Object
      def try(& : self -> U) : U forall U
      end

      def itself : self
      end
    end

    module Replicator
      def delete_file(path : String) : Int32
      end
    end

    class Follower
      include Replicator
    end

    class Queue
      def run(replicator : Replicator) : Nil
        replicator.itself.size
        replicator.try { |follower| follower.delete_file("a").size }
      end
    end
    CR

  it "keeps the module as self for a method its includers inherit from Object" do
    receiver_of_size(source, "replicator.itself.size").should eq("Replicator")
  end

  it "types a block parameter yielded as self by an Object method" do
    receiver_of_size(source, "follower.delete_file(\"a\").size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "receiverless macro calls" do
  source = <<-CR
    class Queue
      private macro parse_header(header, type)
        {{type}}.new
      end

      def run : Nil
        parse_header("ttl", Int32).size
        missing("ttl").size
      end
    end
    CR

  it "says a receiverless call to a macro is a macro" do
    receiver_of_size(source, "parse_header(\"ttl\", Int32).size").should eq(
      "unknown (macro: `parse_header` is a macro; its expansion is not typed)"
    )
  end

  it "keeps an unknown name unresolved" do
    receiver_of_size(source, "missing(\"ttl\").size").should eq(
      "unknown (unresolved name: no `missing` on Queue)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "boolean operators" do
  source = <<-CR
    class Flag
      def run(name : String?, value) : Nil
        (!value).size
        name.nil?.size
        value.is_a?(String).size
        value.responds_to?(:size).size
      end
    end
    CR

  it "types a negation as Bool whatever its operand" do
    receiver_of_size(source, "(!value).size").should eq("Bool")
  end

  it "types nil?, is_a? and responds_to? as Bool" do
    receiver_of_size(source, "name.nil?.size").should eq("Bool")
    receiver_of_size(source, "value.is_a?(String).size").should eq("Bool")
    receiver_of_size(source, "value.responds_to?(:size).size").should eq("Bool")
  end
end

describe Heucristic::Resolve::Receiver, "untyped nil-asserting accessors" do
  source = <<-CR
    class Store
    end

    class Server
      getter! store

      def initialize
        @store = nil
        @store = Store.new
      end

      def run : Nil
        store.size
        store?.size
      end
    end
    CR

  it "types the asserting reader as its ivar without Nil" do
    receiver_of_size(source, "store.size").should eq("Store")
  end

  it "types the query reader as its ivar" do
    receiver_of_size(source, "store?.size").should eq("Nil | Store")
  end
end

describe Heucristic::Resolve::Receiver, "accessor blocks" do
  source = <<-CR
    class State
      def current : String
      end
    end

    class Context
      getter state : State { State.new }
      getter title : String { state.current.size }
      class_getter shared : State { build.current.size }

      def self.build : State
      end
    end
    CR

  it "types implicit self inside an instance accessor's block as the instance" do
    receiver_of_size(source, "state.current.size").should eq("String")
  end

  it "keeps implicit self inside a class accessor's block as the metaclass" do
    receiver_of_size(source, "build.current.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "proc literal closures" do
  source = <<-CR
    class Factory
      def self.build : String
      end

      def self.make : Nil
        -> { build.size }
      end

      def run(name : String, maybe : String?, count : Int32) : Nil
        -> { name.size }
        if maybe
          -> { maybe.size }
        end
        ->(own : Int32) { own.size }
        moved = 1
        -> { moved.size }
        moved = "s"
        [1].each { |count| -> { count.size } }
      end
    end
    CR

  it "types a captured parameter from the enclosing def" do
    receiver_of_size(source, "name.size").should eq("String")
  end

  it "keeps the narrowing in force where the proc is created" do
    receiver_of_size(source, "maybe.size").should eq("String")
  end

  it "types the proc's own parameter from its restriction" do
    receiver_of_size(source, "own.size").should eq("Int32")
  end

  it "gives up on a captured variable reassigned after the proc" do
    receiver_of_size(source, "moved.size").should eq(
      "unknown (inference needed: moved is captured by a proc and reassigned after it)"
    )
  end

  it "types implicit self inside a proc in a class method as the metaclass" do
    receiver_of_size(source, "build.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "modules that extend themselves" do
  source = <<-CR
    module Spinner
      extend self

      class_property? enabled : Bool = false

      def self.frames : Array(String)
      end

      def label : String
      end

      def run : Nil
        frames.size
        label.size
        missing.size
      end
    end
    CR

  it "resolves an implicit call in an instance def against the module's class methods" do
    receiver_of_size(source, "frames.size").should eq("Array(String)")
  end

  it "prefers the module's instance methods" do
    receiver_of_size(source, "label.size").should eq("String")
  end

  it "still reports a name neither side declares" do
    receiver_of_size(source, "missing.size").should eq(
      "unknown (unresolved name: no `missing` on Spinner)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "calls on an abstract base its subclasses answer" do
  source = <<-CR
    abstract class Shape
    end

    abstract class Rounded < Shape
      def name : String
      end
    end

    class Circle < Rounded
      def area : Float64
      end
    end

    class Square < Shape
      def area : Int32
      end

      def name : String
      end
    end

    abstract class Partial
    end

    class Full < Partial
      def x : Int32
      end
    end

    class Empty < Partial
    end

    class Runner
      def run(shape : Shape, partial : Partial) : Nil
        shape.area.size
        shape.name.size
        partial.x.size
      end
    end
    CR

  it "unions the results of every concrete subclass (crystal run: Float64 | Int32)" do
    receiver_of_size(source, "shape.area.size").should eq("Float64 | Int32")
  end

  it "finds a method an abstract intermediate defines (crystal run: String)" do
    receiver_of_size(source, "shape.name.size").should eq("String")
  end

  it "names the concrete subclass that lacks the method, as the compiler does" do
    receiver_of_size(source, "partial.x.size").should eq(
      "unknown (unresolved name: no `x` on Empty, a subclass of Partial)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "macro calls through a constant and their blocks" do
  source = <<-CR
    module GraphQL
      macro fragment(name, &block)
      end
    end

    module Queries
      ::GraphQL.fragment Comments do
        on PullRequest do
          comments(last: 100) do
            body String
          end
        end
      end

      def self.run : Nil
        missing.size
      end
    end
    CR

  it "says a call to a macro through its owning constant is a macro" do
    receiver_of_size(
      source.sub("::GraphQL.fragment Comments do", "::GraphQL.fragment(Comments).size do"),
      "::GraphQL.fragment(Comments).size",
    ).should eq("unknown (macro: `fragment` is a macro; its expansion is not typed)")
  end

  it "says a call nested in a macro's block is the macro's to define" do
    receiver_of_size(
      source.sub("body String", "body(String).size"), "body(String).size"
    ).should eq(
      "unknown (macro: `body` sits inside the `fragment` macro, which decides what it means)"
    )
  end

  it "keeps an unknown name outside any macro unresolved" do
    receiver_of_size(source, "missing.size").should eq(
      "unknown (unresolved name: no `missing` on Queries.class)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "generic records" do
  source = <<-CR
    module GraphQL
      record Envelope(T), data : T, errors : Array(String) do
        def first_error : Nil
          errors.size
        end
      end

      def self.run(envelope : Envelope(Int32)) : Nil
        envelope.data.size
      end
    end
    CR

  it "types a getter of a generic record inside its block" do
    receiver_of_size(source, "errors.size").should eq("Array(String)")
  end

  it "binds a generic record's type variable through its use" do
    receiver_of_size(source, "envelope.data.size").should eq("Int32")
  end
end

describe Heucristic::Resolve::Receiver, "inherited type variables as values" do
  source = <<-CR
    class Array(T)
      def self.new : self
      end

      def size : Int32
      end
    end

    abstract struct Base(T)
    end

    struct List < Base(Array(String))
      def fresh : Nil
        T.size
      end
    end
    CR

  it "binds a parent's type variable used as a value through the subclass" do
    receiver_of_size(source, "T.size").should eq("Array(String).class")
  end
end

describe Heucristic::Resolve::Receiver, "free variables in a union block restriction" do
  source = <<-CR
    class Failure
    end

    class Other
    end

    class Shift
    end

    class Prompt
      def ask(& : String -> T | Failure) : T? forall T
      end

      def run(fail : Bool) : Nil
        ask { |answer| fail ? Failure.new : Shift.new }.size
        nexted = ask do |answer|
          next Other.new if fail
          Shift.new
        end
        nexted.size
      end
    end
    CR

  it "binds the free member to what the other members do not cover (crystal run: Shift | Nil)" do
    receiver_of_size(source, "ask { |answer| fail ? Failure.new : Shift.new }.size").should eq(
      "Shift | Nil"
    )
  end

  it "counts a block's next values in its result (crystal run: Other | Shift | Nil)" do
    receiver_of_size(source, "nexted.size").should eq("Other | Shift | Nil")
  end
end

describe Heucristic::Resolve::Receiver, "subclass dispatch through blocks and metaclasses" do
  source = <<-CR
    class Channel
      def rate : Int32
      end
    end

    abstract class Client
      def self.build : String
        algorithm.size
      end
    end

    class AmqpClient < Client
      def self.algorithm : String
      end

      def each_channel(& : Channel ->) : Nil
      end
    end

    class MqttClient < Client
      def self.algorithm : String
      end

      def each_channel(& : Channel ->) : Nil
      end
    end

    class Server
      def run(client : Client) : Nil
        client.each_channel { |channel| channel.rate.size }
      end
    end
    CR

  it "types a block parameter of a method every concrete subclass yields" do
    receiver_of_size(source, "channel.rate.size").should eq("Int32")
  end

  it "types a class method only the concrete subclasses define (crystal: String)" do
    receiver_of_size(source, "algorithm.size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "calls inside annotations" do
  source = <<-CR
    annotation Opt
    end

    class Cli
      @[Opt("--expires", value: v(1).size)]
      def run : Nil
      end
    end
    CR

  it "says a call in an annotation's arguments is for macros to read" do
    receiver_of_size(source, "v(1).size").should eq(
      "unknown (macro: `v` sits inside an annotation, whose arguments only macros read)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "forward_missing_to" do
  source = <<-CR
    class Store
      def lookup(key : String) : Bool?
      end
    end

    class Cache
      @store = Store.new

      forward_missing_to @store
    end

    class User
      def allowed?(cache : Cache) : Nil
        cache.lookup("a").size
        cache.missing.size
      end
    end
    CR

  it "types a call the receiver lacks through its forward_missing_to target" do
    receiver_of_size(source, "cache.lookup(\"a\").size").should eq("Bool | Nil")
  end

  it "reports a call the forward target lacks as missing there" do
    receiver_of_size(source, "cache.missing.size").should eq(
      "unknown (unresolved name: no `missing` on Store)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "macros reached through a receiver's type" do
  source = <<-CR
    struct Number
      macro static_array(*nums)
      end
    end

    struct Slice(T)
      macro [](*args, read_only = false)
      end
    end

    alias Bytes = Slice(UInt8)

    module ClassMethods
      macro from_errno(message)
      end
    end

    class Failure
      extend ClassMethods
    end

    class Runner
      def run : Nil
        UInt8.static_array(1, 2).size
        Bytes[1, 2].size
        Failure.from_errno("x").size
        UInt8.nothing.size
      end
    end
    CR

  it "finds a macro an ancestor of the receiver's type owns" do
    receiver_of_size(source, "UInt8.static_array(1, 2).size").should eq(
      "unknown (macro: `static_array` is a macro; its expansion is not typed)"
    )
  end

  it "finds a macro through an alias of the receiver" do
    receiver_of_size(source, "Bytes[1, 2].size").should eq(
      "unknown (macro: `[]` is a macro; its expansion is not typed)"
    )
  end

  it "types an aliased literal macro from its inlined expansion (crystal run: Slice(UInt8))" do
    expanded = [
      "slice = ::Slice(UInt8).new(2, read_only: false)",
      "slice.to_unsafe[0] = UInt8.new!(1)",
      "slice",
    ].join('\n')
    expansions = [expansion_at(source, "[1, 2]", "[]", expanded)]
    receiver_of_size(source, "Bytes[1, 2].size", expansions).should eq("Slice(UInt8)")
  end

  it "finds a macro in a module the receiver's type extends" do
    receiver_of_size(source, "Failure.from_errno(\"x\").size").should eq(
      "unknown (macro: `from_errno` is a macro; its expansion is not typed)"
    )
  end

  it "keeps a name no level declares unresolved" do
    receiver_of_size(source, "UInt8.nothing.size").should eq(
      "unknown (unresolved name: no `nothing` on UInt8.class)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "constants the compiler defines" do
  source = <<-CR
    class Report
      def run : Nil
        Crystal::DESCRIPTION.size
        Crystal::BUILD_COMMIT.size
        Crystal::USER_FLAGS.size
      end
    end
    CR

  it "types a compiler-defined string constant (program.cr: define_crystal_string_constant)" do
    receiver_of_size(source, "Crystal::DESCRIPTION.size").should eq("String")
  end

  it "types the build commit as nilable, as a compiler built without one defines it as nil" do
    receiver_of_size(source, "Crystal::BUILD_COMMIT.size").should eq("String | Nil")
  end

  it "types the flag constants as string arrays (program.cr: define_string_array_constant)" do
    receiver_of_size(source, "Crystal::USER_FLAGS.size").should eq("Array(String)")
  end
end

describe Heucristic::Resolve::Receiver, "constants a macro sets" do
  it "types an exported value and explains a value the helper could not export" do
    caller = <<-CR
      class Controller
        def run : Nil
          Log.size
          Hidden.size
        end
      end
      CR
    generated = <<-CR
      class ::Controller
        Log = "bindings"
        Hidden = uninitialized ::Nil
      end
      CR
    files = {"a.cr" => caller, "<macros>" => generated}
    receiver_across(files, "a.cr", "Log.size").should eq("String")
    receiver_across(files, "a.cr", "Hidden.size").should eq(
      "unknown (macro: Controller::Hidden is set by a macro whose value the helper did not export)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "yields inside macro code" do
  source = <<-CR
    struct Pair(T)
      def reduce(&)
        {% for i in 0...2 %}
          yield self[{{ i }}]
        {% end %}
      end
    end

    class Folder
      def run(pair : Pair(Int32)) : Nil
        pair.reduce { |value| value.size }
      end
    end
    CR

  it "says a def yields only inside macro code instead of claiming it never yields" do
    receiver_of_size(source, "value.size").should eq(
      "unknown (macro: Pair#reduce yields only inside macro code)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "unpacked block parameters in a block's result" do
  source = <<-CR
    class Array(T)
      def map(& : T -> U) : Array(U) forall U
      end
    end

    class Pairs
      def run(pairs : Array(Tuple(String, Int32))) : Nil
        pairs.map { |(name, count)| name }.size
      end
    end
    CR

  it "binds unpacked block parameters when typing the block's result" do
    receiver_of_size(source, "pairs.map { |(name, count)| name }.size").should eq("Array(String)")
  end
end

describe Heucristic::Resolve::Receiver, "typeof as a value" do
  source = <<-CR
    class Probe
      def run(text : String, number : Int32) : Nil
        typeof(text).size
        typeof(text, number).size
      end
    end
    CR

  it "types typeof of an expression as its metaclass" do
    receiver_of_size(source, "typeof(text).size").should eq("String.class")
  end

  it "types typeof of several expressions as the metaclass of their union" do
    receiver_of_size(source, "typeof(text, number).size").should eq("String.class | Int32.class")
  end
end

describe Heucristic::Resolve::Receiver, "overloads chosen with the receiver's type arguments" do
  source = <<-CR
    class Box(T)
      def put(value : T) : T
      end

      def put(values : Array(T)) : Array(T)
      end

      def dig(key : String) : Int32
      end

      def dig(key : String, *rest) : String
      end
    end

    module Comparable(T)
      def ==(other : T) : Bool
      end
    end

    struct Value
      def ==(other) : String
      end
    end

    struct Version < Value
      include Comparable(Version)
    end

    class Runner
      def run(box : Box(Int32), version : Version) : Nil
        box.put([1]).size
        box.dig("a").size
        (version == 1).size
      end
    end
    CR

  it "drops an overload whose restriction the receiver's type argument rules out" do
    receiver_of_size(source, "box.put([1]).size").should eq("Array(Int32)")
  end

  it "prefers the overload without a splat (crystal run: Int32)" do
    receiver_of_size(source, "box.dig(\"a\").size").should eq("Int32")
  end

  it "moves past an ancestor whose restriction rejects the argument" do
    receiver_of_size(source, "(version == 1).size").should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "dispatch and stdlib specials" do
  source = <<-CR
    class Node
      def location : Nil
      end
    end

    class Leaf < Node
      def location : String
      end
    end

    abstract class Shape
      def area : Int32
      end
    end

    class Square < Shape
    end

    class Circle < Shape
      def area : Float64
      end
    end

    class Stream
      def close : Nil
      end
    end

    class Wrapped < Stream
      def initialize(@inner : Stream)
      end

      delegate close, to: @inner
    end

    struct Tuple(*T)
      def types : T
      end

      def [](index : Int) : Union(*T)
      end

      def first : Union(*T)
      end
    end

    struct NamedTuple
      def values
      end

      def keys
      end
    end

    struct Enum
      def self.each(& : self -> U) : U? forall U
      end
    end

    enum Color
      Red
      Green
    end

    module Spec
      struct BeNilExpectation
      end

      module ObjectExtensions
        def should_not(expectation) : self
        end
      end
    end

    class Object
      include Spec::ObjectExtensions
    end

    class Runner
      def run(
        node : Node,
        shape : Shape,
        stream : Stream,
        pair : Tuple(Int32, String),
        bare : Tuple,
      ) : Nil
        node.location.size
        shape.area.size
        stream.close.size
        pair[1]?.size
        bare.types.size
        bare[0].size
        bare.first.size
        named = {a: 1, b: "x"}
        named.values.size
        named.keys.size
        Color.each { |color| 1 }.size
        nil.should_not(Spec::BeNilExpectation.new).size
        maybe : Int32? = nil
        maybe.size
      end
    end
    CR

  it "unions the overrides of a subclass for a virtual receiver (crystal run: String | Nil)" do
    receiver_of_size(source, "node.location.size").should eq("Nil | String")
  end

  it "keeps an inherited def beside an override when abstract (crystal run: Float64 | Int32)" do
    receiver_of_size(source, "shape.area.size").should eq("Float64 | Int32")
  end

  it "drops a subclass that delegates back to the same virtual call (crystal run: Nil)" do
    receiver_of_size(source, "stream.close.size").should eq("Nil")
  end

  it "types a tuple's []? with an in-range literal as the element (crystal run: String)" do
    receiver_of_size(source, "pair[1]?.size").should eq("String")
  end

  it "leaves a bare Tuple's splat type variable unbound instead of the empty tuple" do
    receiver_of_size(source, "bare.types.size").should eq("T")
  end

  it "does not read a bare Tuple as the empty tuple" do
    receiver_of_size(source, "bare[0].size").should eq("unknown (unsupported: *T)")
    receiver_of_size(source, "bare.first.size").should eq("unknown (unsupported: *T)")
  end

  it "types NamedTuple#values and #keys from the labels (crystal run: Tuple(Int32, String))" do
    receiver_of_size(source, "named.values.size").should eq("Tuple(Int32, String)")
    receiver_of_size(source, "named.keys.size").should eq("Tuple(Symbol, Symbol)")
  end

  it "types Enum.each on an enum with members as the block result (crystal run: Int32)" do
    receiver_of_size(source, "Color.each { |color| 1 }.size").should eq("Int32")
  end

  it "types nil.should_not be_nil as NoReturn (crystal run: NoReturn)" do
    receiver_of_size(source, "nil.should_not(Spec::BeNilExpectation.new).size").should eq(
      "NoReturn"
    )
  end

  it "types a declared local from its value (crystal run: maybe : Int32? = nil is Nil)" do
    receiver_of_size(source, "maybe.size").should eq("Nil")
  end
end

describe Heucristic::Resolve::Receiver, "macro expansions" do
  source = <<-CR
    class Crate
      macro make(value)
        {{ value }}
      end

      macro shadow
        value = "text"
        value
      end

      macro nested
        if value = maybe
          value
        end
      end

      macro branchy
        if maybe
          value = 1
        end
        value
      end

      def maybe : Int32?
      end

      def run : Nil
        make("a").size
      end

      def outer : Nil
        value = "outer"
        nested.size
        branchy.size
      end

      def assigned : Nil
        value = 1
        shadow.size
        value.size
      end
    end
    CR

  expansions = [
    expansion_at(source, %(make("a")), "make", %("a")),
    expansion_at(source, "shadow.size", "shadow", %(value = "text"\nvalue)),
    expansion_at(source, "nested.size", "nested", "if value = maybe\n  value\nend"),
    expansion_at(source, "branchy.size", "branchy", "if maybe\n  value = 1\nend\nvalue"),
  ]

  it "types a macro call from its expansion (crystal run: String)" do
    receiver_of_size(source, %(make("a").size), expansions).should eq("String")
  end

  it "types the expansion's own straight-line locals (crystal run: String)" do
    receiver_of_size(source, "shadow.size", expansions).should eq("String")
  end

  it "keeps the expansion's locals apart from the def's (crystal run: Int32 | Nil)" do
    receiver_of_size(source, "nested.size", expansions).should eq("Int32 | Nil")
  end

  it "leaves a local the expansion assigns in a branch unknown (crystal run: Int32 | Nil)" do
    receiver_of_size(source, "branchy.size", expansions).should eq(
      "unknown (macro: `value` is assigned inside the expansion of `branchy` " \
      "where flow decides its type)"
    )
  end

  it "stops typing a def's local that an expansion reassigns (crystal run: String)" do
    receiver_of_size(source, "value.size", expansions).should eq(
      "unknown (macro: `value` is assigned by the expansion of `shadow`, " \
      "which flow does not follow)"
    )
  end

  it "says the macro is untyped when no expansion is known" do
    receiver_of_size(source, %(make("a").size)).should eq(
      "unknown (macro: `make` is a macro; its expansion is not typed)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "macro expansions with a begin block" do
  source = <<-CR
    def raise(error : Exception) : NoReturn
    end

    class Channel(T)
      def initialize(capacity : Int32)
      end

      def receive : T
      end
    end

    class Crate
      def self.text : String
      end

      macro gather
        channel = Channel(typeof(Crate.text) | Exception).new(1)
        Tuple.new(
          begin
            received = channel.receive
            received.is_a?(Exception) ? raise received : received
          end,
          1,
        )
      end

      macro wrapped
        begin
          value = "text"
          value
        end
      end

      def run : Nil
        gather[0].size
        wrapped.size
      end
    end
    CR

  expansions = [
    expansion_at(
      source, "gather[0]", "gather",
      "channel = Channel(typeof(Crate.text) | Exception).new(1)\nTuple.new(\n  begin\n" \
      "    received = channel.receive\n" \
      "    received.is_a?(Exception) ? raise received : received\n" \
      "  end,\n  1,\n)"
    ),
    expansion_at(source, "wrapped.size", "wrapped", "begin\n  value = \"text\"\n  value\nend"),
  ]

  it "types a begin's straight-line assignments inside a call argument (crystal run: String)" do
    receiver_of_size(source, "gather[0].size", expansions).should eq("String")
  end

  it "types a top-level begin's straight-line assignments (crystal run: String)" do
    receiver_of_size(source, "wrapped.size", expansions).should eq("String")
  end
end

describe Heucristic::Resolve::Receiver, "memoised call results" do
  source = <<-CR
    class Out
      def put(value : Int32) : Out
        self
      end

      def done : Out
        self
      end
    end

    class Builder
      def build(& : Out ->) : Nil
      end
    end

    def go(list : Array(Int32), builder : Builder) : Nil
      builder.build do |io|
        unless list.empty?
          io.put(1).put(2).done
        end
        io.put(3).done
      end
    end
    CR

  markers = {"io.put(3).done", "io.put(1).put(2).done"}

  it "answers every call as a fresh receiver would, whichever is asked first" do
    tree = Heucristic::Syntax.parse(source, "a.cr")
    raise "syntax error" if tree.is_a?(Heucristic::Syntax::Broken)

    build = -> : Heucristic::Resolve::Receiver {
      workspace = Heucristic::Index::Workspace.new
      workspace.update(
        Heucristic::Index::Collector.collect(
          "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
        )
      )
      types = Heucristic::Resolve::Types.new(workspace)
      methods = Heucristic::Resolve::Methods.new(workspace, types)
      Heucristic::Resolve::Receiver.new(workspace, Heucristic::Index::Shims.new, types, methods)
    }
    answer = ->(receiver : Heucristic::Resolve::Receiver, marker : String) : String {
      line = source.lines.index!(&.includes?(marker)) + 1
      column = source.lines[line - 1].index!(".done") + 2
      target = Heucristic::Syntax::Cursor.find(
        tree, Heucristic::Document::Point.new(line, column), "a.cr", SPEC_CRYSTAL, source
      )
      case target
      in Heucristic::Syntax::OnCall then receiver.of_call(target.node, target.context).to_s
      in Heucristic::Syntax::OnDef,
         Heucristic::Syntax::OnPath,
         Heucristic::Syntax::OnVar,
         Heucristic::Syntax::OnInstanceVar,
         Heucristic::Syntax::OnName,
         Heucristic::Syntax::OnRequire,
         Nil
        "no call"
      end
    }

    fresh = markers.map { |marker| answer.call(build.call, marker) }.to_a
    fresh.should eq({"Out", "Out"}.to_a)
    [markers, markers.reverse].each do |order|
      shared = build.call
      order.each do |marker|
        answer.call(shared, marker).should eq(fresh[markers.index!(marker)])
      end
    end
  end
end

describe Heucristic::Resolve::Receiver, "memo contexts that share a fingerprint" do
  source = <<-CR
    def f(x : Box?) : Nil
      1
      if x
        2
        x.size
      end
    end

    class Box
      def size : Int32
        1
      end
    end
    CR

  it "answers a context differing only in a middle ancestor with its own result" do
    tree = Heucristic::Syntax.parse(source, "a.cr")
    raise "syntax error" if tree.is_a?(Heucristic::Syntax::Broken)

    workspace = Heucristic::Index::Workspace.new
    workspace.update(
      Heucristic::Index::Collector.collect(
        "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
      )
    )
    types = Heucristic::Resolve::Types.new(workspace)
    methods = Heucristic::Resolve::Methods.new(workspace, types)
    shims = Heucristic::Index::Shims.new
    receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    target = Heucristic::Syntax::Cursor.find(
      tree, Heucristic::Document::Point.new(5, 7), "a.cr", SPEC_CRYSTAL, source
    )
    raise "cursor did not land on a call" unless target.is_a?(Heucristic::Syntax::OnCall)

    narrowed = target.context
    middle = narrowed.ancestors.index!(&.is_a?(Crystal::If))
    ancestors = narrowed.ancestors.dup
    ancestors[middle] = Crystal::Expressions.new
    widened = Heucristic::Syntax::Context.new(
      narrowed.enclosing, narrowed.type_vars, narrowed.def_node, narrowed.blocks,
      ancestors, narrowed.path, narrowed.instance
    )

    fingerprint = ->(context : Heucristic::Syntax::Context) : {Int32, UInt64, UInt64} {
      {context.ancestors.size, context.ancestors.first.object_id, context.ancestors.last.object_id}
    }
    fingerprint.call(widened).should eq(fingerprint.call(narrowed))

    fresh = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
    wide = Heucristic::Resolve::Frame.of(widened)
    narrow = Heucristic::Resolve::Frame.of(narrowed)
    expected = fresh.result_of(target.node, wide).to_s
    expected.should_not eq(receiver.result_of(target.node, narrow).to_s)
    receiver.result_of(target.node, wide).to_s.should eq(expected)
  end
end

describe Heucristic::Resolve::Receiver, "union arguments" do
  source = <<-CR
    class Base
      def same(other) : Int32
      end
    end

    class Text < Base
      def same(other : Text) : Bool
      end
    end

    class Blank
    end

    class Fmt
      def f(x : Int32) : Int32
      end

      def f(x : String) : String
      end

      def wrap(x : T) : Array(T) forall T
      end
    end

    class Use
      def run(
        fmt : Fmt,
        text : Text,
        either : Text | Blank,
        mixed : Int32 | String,
        odd : Int32 | Symbol,
      ) : Nil
        text.same(either).size
        fmt.f(mixed).size
        fmt.f(odd).size
        fmt.wrap(mixed).size
      end
    end
    CR

  it "types a call per member when an overload admits only some of them (compiler: Bool | Int32)" do
    receiver_of_size(source, "text.same(either).size").should eq("Bool | Int32")
  end

  it "selects each member's overload from the user's overloads (compiler: Int32 | String)" do
    receiver_of_size(source, "fmt.f(mixed).size").should eq("Int32 | String")
  end

  it "gives up when a member has no overload (compiler: no overload matches Symbol)" do
    receiver_of_size(source, "fmt.f(odd).size").should eq(
      "unknown (unresolved name: no overload of `f` accepts every member of its arguments)"
    )
  end

  it "keeps the whole union when one overload covers every member (Array(Int32 | String))" do
    receiver_of_size(source, "fmt.wrap(mixed).size").should eq("Array(Int32 | String)")
  end
end

describe Heucristic::Resolve::Receiver, "union arguments across ancestors" do
  source = <<-CR
    class Par
      def h(x : Int32) : Int64
      end

      def h(x : String) : Float64
      end
    end

    class Chi < Par
      def h(x : Int32) : Bool
      end
    end

    class Whole < Par
      def h(x : Int32 | String) : Bool
      end
    end

    class Each < Par
      def h(x : Int32) : Bool
      end

      def h(x : String) : Char
      end
    end

    module Extra
      def h(x : Int32) : Char
      end
    end

    class Mixed
      include Extra

      def h(x : String) : Int64
      end
    end

    class Pair
      def g(a : Int32, b : Int32) : Int64
      end

      def g(a : String, b : Int32) : Float64
      end

      def g(a : Int32, b : String) : Bool
      end

      def g(a : String, b : String) : Char
      end
    end

    class Use
      def run(
        chi : Chi,
        whole : Whole,
        each : Each,
        mixed : Mixed,
        virt : Par,
        pair : Pair,
        u : Int32 | String,
        v : Int32 | String,
      ) : Nil
        chi.h(u).size
        whole.h(u).size
        each.h(u).size
        mixed.h(u).size
        virt.h(u).size
        pair.g(u, v).size
      end
    end
    CR

  it "keeps the overridden parent overload reachable (compiler: Bool | Float64 | Int64)" do
    receiver_of_size(source, "chi.h(u).size").should eq("Bool | Int64 | Float64")
  end

  it "stops at a closer def covering the whole union (compiler: Bool)" do
    receiver_of_size(source, "whole.h(u).size").should eq("Bool")
  end

  it "stops at a closer def per member (compiler: Bool | Char)" do
    receiver_of_size(source, "each.h(u).size").should eq("Bool | Char")
  end

  it "walks an included module then the parent (compiler: Char | Int64)" do
    receiver_of_size(source, "mixed.h(u).size").should eq("Int64 | Char")
  end

  it "adds the subclass overrides of a virtual receiver (compiler: all four)" do
    receiver_of_size(source, "virt.h(u).size").should eq("Int64 | Float64 | Bool | Char")
  end

  it "splits over every union argument (compiler: Bool | Char | Float64 | Int64)" do
    receiver_of_size(source, "pair.g(u, v).size").should eq("Int64 | Float64 | Bool | Char")
  end
end

describe Heucristic::Resolve::Receiver, "union arguments to class methods" do
  source = <<-CR
    class Par
      def self.k(x : Int32) : Int64
      end

      def self.k(x : String) : Float64
      end
    end

    class Chi < Par
      def self.k(x : Int32) : Bool
      end
    end

    class Whole < Par
      def self.k(x : Int32 | String) : Bool
      end
    end

    class Each < Par
      def self.k(x : Int32) : Bool
      end

      def self.k(x : String) : Char
      end
    end

    module Extra
      def k(x : Int32) : Char
      end
    end

    class Mixed < Par
      extend Extra
    end

    class Foo
      def initialize(x : Int32)
      end

      def initialize(x : String)
      end
    end

    class Use
      def run(u : Int32 | String) : Nil
        Foo.new(u).size
        Chi.k(u).size
        Whole.k(u).size
        Each.k(u).size
        Mixed.k(u).size
      end
    end
    CR

  it "keeps the overridden parent class method reachable (compiler: Bool | Float64 | Int64)" do
    receiver_of_size(source, "Chi.k(u).size").should eq("Bool | Int64 | Float64")
  end

  it "stops at a closer def covering the whole union (compiler: Bool)" do
    receiver_of_size(source, "Whole.k(u).size").should eq("Bool")
  end

  it "stops at a closer def per member (compiler: Bool | Char)" do
    receiver_of_size(source, "Each.k(u).size").should eq("Bool | Char")
  end

  it "types new over each constructor the members reach (compiler: Foo)" do
    receiver_of_size(source, "Foo.new(u).size").should eq("Foo")
  end

  it "gives up when an extended module sits in the chain" do
    receiver_of_size(source, "Mixed.k(u).size").should eq(
      "unknown (unresolved name: no overload of `k` accepts every member of its arguments)"
    )
  end
end

describe Heucristic::Resolve::Receiver, "constructor calls with a class-level new" do
  source = <<-CR
    class Plain
      def initialize(x : Int32)
      end
    end

    class Factory
      def initialize(x : Int32)
      end

      def self.new(x : Int32) : Int32
        1
      end
    end

    class Parent
      def initialize(x : Int32)
      end
    end

    class Child < Parent
      def self.new(x : Int32) : Int32
        1
      end
    end

    def probe
      Plain.new(1).size
      Factory.new(1).size
      Child.new(1).size
    end
    CR

  it "types a constructor call from the new the compiler picks, not as an instance by default" do
    receiver_of_size(source, "Plain.new(1).size").should eq("Plain")
    receiver_of_size(source, "Child.new(1).size").should eq("Int32")
    receiver_of_size(source, "Factory.new(1).size").should start_with("unknown")
  end

  it "types a variable assigned from a constructor call the same way on every reference" do
    variables = <<-CR
      #{source}

      def reuse
        plain = Plain.new(1)
        child = Child.new(1)
        plain.size
        plain.size
        child.size
        child.size
      end
      CR

    references = %w[plain.size child.size]
    answers = variables.lines.each_with_index.compact_map do |text, index|
      next unless references.includes?(text.strip)

      column = text.index!(text.strip) + text.strip.rindex!("size") + 1
      receiver_at(variables, index + 1, column)
    end
    answers.to_a.should eq(%w[Plain Plain Int32 Int32])
  end
end

describe Heucristic::Resolve::Receiver, "a written self.new without a return restriction" do
  source = <<-CR
    class Other
    end

    class Weird
      def self.new
        Other.new
      end
    end

    class Both
      def initialize(x : Int32)
      end

      def self.new(x : Int32)
        1
      end
    end

    class Default
      def initialize(x : Int32)
      end
    end

    def probe
      Weird.new.size
      Both.new(1).size
      Default.new(1).size
    end
    CR

  it "is unknown, while the initialize-derived new is the instance" do
    receiver_of_size(source, "Weird.new.size").should start_with("unknown (no annotation")
    receiver_of_size(source, "Both.new(1).size").should start_with("unknown")
    receiver_of_size(source, "Default.new(1).size").should eq("Default")
  end

  it "is unknown when a macro generated it" do
    files = {
      "a.cr"     => "class MacroNew\nend\n\nMacroNew.new.size\n",
      "<macros>" => "class MacroNew\n  def self.new\n    Other.new\n  end\nend\n",
    }
    receiver_across(files, "a.cr", "MacroNew.new.size").should start_with("unknown (no annotation")
  end
end

describe Heucristic::Resolve::Receiver, "splat type variables" do
  source = <<-CR
    struct Tuple(*T)
      def self.new(*args : *T) : Tuple(*T)
      end

      def [](index : Int) : Union(*T)
      end
    end

    class Gatherer
      def gather(label : String, *items : *T) : Tuple(*T) forall T
      end

      def run(number : Int32, rest : Tuple(Int32, String), any : Tuple) : Nil
        any.size
        pair = Tuple.new(number, "a")
        pair.size
        pair[1].size
        pair[0].size
        pair[2].size
        gather("x", number, "a")[1].size
        gather("x").size
        Tuple.new(number, mystery).size
        Tuple.new(*rest).size
      end
    end
    CR

  it "binds a splat parameter's *T to the argument tuple (crystal run: Tuple(Int32, String))" do
    receiver_of_size(source, "pair.size").should eq("Tuple(Int32, String)")
    receiver_of_size(source, "pair[1].size").should eq("String")
    receiver_of_size(source, "pair[0].size").should eq("Int32")
  end

  it "binds a def's own splat variable after leading parameters" do
    receiver_of_size(source, "gather(\"x\", number, \"a\")[1].size").should eq("String")
  end

  it "renders an empty splat pack as Tuple() (crystal run: Tuple())" do
    receiver_of_size(source, "gather(\"x\").size").should eq("Tuple()")
  end

  it "does not call a bare Tuple restriction an empty tuple" do
    receiver_of_size(source, "any.size").should_not eq("Tuple()")
  end

  it "says a tuple has no element past its bound size" do
    receiver_of_size(source, "pair[2].size").should contain("has no element 2")
  end

  it "is unknown when an argument or a call splat hides the tuple's elements" do
    receiver_of_size(source, "Tuple.new(number, mystery).size").should start_with("unknown")
    receiver_of_size(source, "Tuple.new(*rest).size").should start_with("unknown")
  end
end

describe Heucristic::Resolve::Receiver, "nested and union block unpacking" do
  source = <<-CR
    module Enumerable(T)
      def each(& : T ->) : Nil
      end

      def map(& : T -> U) : Array(U) forall U
      end
    end

    class Array(T)
      include Enumerable(T)

      def [](index : Int) : T
      end
    end

    class Hash(K, V)
      include Enumerable(Tuple(K, V))
    end

    class Lookup
      def [](index : Int) : String
      end
    end

    class Table
      def run(
        nested : Array(Tuple(Int32, Tuple(String, Symbol))),
        keyed : Hash(Int32, Tuple(String, Float64)),
        mixed : Array(Tuple(Int32, String) | Array(Int32)),
        lookups : Array(Lookup),
        deep : Array(Tuple(Int32, Tuple(String, Tuple(Symbol, Float64)))),
      ) : Nil
        nested.each { |(number, (text, symbol))| number.size; text.size; symbol.size }
        keyed.each { |key, (text, float)| key.size; text.size; float.size }
        mixed.each { |(head, tail)| head.size; tail.size }
        lookups.each { |(first, second)| first.size }
        nested.map { |(number, (text, symbol))| symbol }.size
        deep.each { |(number, (text, (symbol, float)))| float.size }
        nested.each { |(number, (text, symbol, extra))| extra.size }
      end
    end
    CR

  it "types the targets of a nested unpacking (crystal run: Int32 String Symbol)" do
    receiver_of_size(source, "number.size").should eq("Int32")
    receiver_of_size(source, "text.size").should eq("String")
    receiver_of_size(source, "symbol.size }").should eq("Symbol")
    receiver_of_size(source, "(symbol, float)))| float.size").should eq("Float64")
  end

  it "types a nested target after a plain parameter (crystal run: Int32 String Float64)" do
    receiver_of_size(source, "key.size").should eq("Int32")
    receiver_of_size(source, "float.size }").should eq("Float64")
  end

  it "unpacks each member of a union element (crystal run: Int32, String | Int32)" do
    receiver_of_size(source, "head.size").should eq("Int32")
    receiver_of_size(source, "tail.size").should eq("String | Int32")
  end

  it "types a target through the element's own [] (crystal run: String)" do
    receiver_of_size(source, "first.size").should eq("String")
  end

  it "binds nested targets when typing the block's result" do
    mapped = "nested.map { |(number, (text, symbol))| symbol }.size"
    receiver_of_size(source, mapped).should eq("Array(Symbol)")
  end

  it "is unknown when a nested unpacking reaches past the tuple (crystal: index out of bounds)" do
    receiver_of_size(source, "extra.size").should start_with("unknown")
  end
end

describe Heucristic::Resolve::Receiver, "block parameters from yields" do
  source = <<-CR
    class Array(T)
      def each(& : T ->) : Nil
      end
    end

    class Bag(T)
      @items : Array(T)
      @pair : Tuple(Int32, String)

      def initialize(@items : Array(T), @pair : Tuple(Int32, String))
      end

      def each
        @items.each { |item| yield item }
      end

      def pairs
        yield 1, "a"
        yield 2, :b
      end

      def either
        yield 1
        yield "a"
      end

      def packed
        yield({1, "a"}, 2.5)
      end

      def spread
        yield *@pair
      end

      def spread_after(count : Float64)
        yield count, *@pair
      end

      def spread_unknown(values : Array(Int32))
        yield *values
      end

      def partial(flag : Bool)
        yield 1, "a"
        yield 2 if flag
      end

      def mystery(thing)
        yield thing
      end

      def local
        items = [1, 2]
        yield items
      end

      def run : Nil
        pairs { |pn, pt| pn.size; pt.size }
        either { |ev| ev.size }
        packed { |pl, pr| pl.size; pr.size }
        packed { |(qa, qb), qc| qa.size; qb.size; qc.size }
        spread { |sn, st| sn.size; st.size }
        spread_after(1.5) { |sd, sn2, st2| sd.size; sn2.size; st2.size }
        spread_unknown([1]) { |ua, ub| ua.size; ub.size }
        partial(true) { |bn, bt| bn.size; bt.size }
        mystery(1) { |mv| mv.size }
        local { |li| li.size }
        each { |ei| ei.size }
      end
    end
    CR

  it "types block parameters from the yield's arguments and joins the sites (crystal run)" do
    receiver_of_size(source, "pn.size").should eq("Int32")
    receiver_of_size(source, "pt.size").should eq("String | Symbol")
    receiver_of_size(source, "ev.size").should eq("Int32 | String")
  end

  it "types a yielded local and a generic owner's type variable" do
    receiver_of_size(source, "li.size").should eq("Array(Int32)")
    receiver_of_size(source, "ei.size").should eq("T")
  end

  it "splats a single yielded tuple across block parameters and unpacks it (crystal run)" do
    receiver_of_size(source, "pl.size").should eq("Tuple(Int32, String)")
    receiver_of_size(source, "pr.size").should eq("Float64")
    receiver_of_size(source, "qa.size").should eq("Int32")
    receiver_of_size(source, "qb.size").should eq("String")
    receiver_of_size(source, "qc.size").should eq("Float64")
  end

  it "spreads a splatted tuple across the yielded values (crystal run: Int32, String)" do
    receiver_of_size(source, "sn.size").should eq("Int32")
    receiver_of_size(source, "st.size").should eq("String")
  end

  it "keeps the positions after a leading argument (crystal run: Float64, Int32, String)" do
    receiver_of_size(source, "sd.size").should eq("Float64")
    receiver_of_size(source, "sn2.size").should eq("Int32")
    receiver_of_size(source, "st2.size").should eq("String")
  end

  it "is unknown for a splat with no known size, a missing value and an unknown argument" do
    receiver_of_size(source, "ua.size").should start_with("unknown")
    receiver_of_size(source, "ub.size").should start_with("unknown")
    receiver_of_size(source, "bn.size").should eq("Int32")
    receiver_of_size(source, "bt.size").should start_with("unknown")
    receiver_of_size(source, "mv.size").should start_with("unknown")
  end
end

describe Heucristic::Resolve::Receiver, "splat block parameters" do
  source = <<-CR
    def pairs(& : Int32, String ->) : Nil
    end

    class Forwarder
      def run : Nil
        pairs { |*rest| rest.size }
        pairs { |first, *rest| first.size; rest.size }
        pairs { |*rest| yield *rest }
      end
    end
    CR

  it "does not type a splat block parameter as the first yielded value (crystal: Tuple)" do
    receiver_of_size(source, "pairs { |*rest| rest.size }").should start_with("unknown")
  end

  it "types the parameter before a splat and leaves the splat unknown" do
    receiver_of_size(source, "first.size").should eq("Int32")
    receiver_of_size(source, "rest.size }").should start_with("unknown")
  end
end
