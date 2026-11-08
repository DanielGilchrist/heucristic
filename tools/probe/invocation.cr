require "./action"
require "./invalid"

module Probe
  record Invocation,
    binary : String,
    file : String,
    line : Int32,
    character : Int32,
    action : Action do
    def self.parse(args : Array(String)) : Invocation | Invalid
      return Invalid.new unless args.size >= 2

      position = args[1].split(':')
      return Invalid.new unless position.size == 2

      line = position[0].to_i32?
      character = position[1].to_i32?
      return Invalid.new unless line && character

      action = Actions.parse(args[2]? || "both")
      return action if action.is_a?(Invalid)

      binary = ENV.fetch("HEUCRISTIC_BIN", File.join(Dir.current, "bin", "heucristic"))
      new(binary, File.expand_path(args[0]), line - 1, character - 1, action)
    end
  end
end
