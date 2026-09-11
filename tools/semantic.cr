require "compiler/requires"
require "json"
require "./semantic/dump"

module Semantic
  def self.run(args : Array(String)) : Int32
    entry = args[0]?
    root = args[1]?
    unless entry && root
      STDERR.puts "usage: heucristic-semantic <entry file> <project root>"
      return 2
    end

    Dump.new(File.expand_path(entry), File.expand_path(root)).write(STDOUT)
    0
  end
end

exit Semantic.run(ARGV)
