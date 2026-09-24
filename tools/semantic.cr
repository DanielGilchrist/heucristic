require "compiler/requires"
require "json"
require "./semantic/dump"

module Semantic
  def self.run(args : Array(String)) : Int32
    entry = args[0]?
    root = args[1]?
    unless entry && root
      STDERR.puts "usage: heucristic-semantic <entry file> <project root> [-Dflag ...]"
      return 2
    end

    defines = args[2..].compact_map(&.lchop?("-D"))
    Dump.new(File.expand_path(entry), File.expand_path(root), defines).write(STDOUT)
    0
  end
end

exit Semantic.run(ARGV)
