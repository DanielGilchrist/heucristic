module Probe
  record Root, path : String
  record NoRoot

  alias Lookup = Root | NoRoot

  module Roots
    extend self

    def find(directory : String) : Lookup
      current = directory
      until current == "/"
        return Root.new(current) if File.exists?(File.join(current, "shard.yml"))

        current = File.dirname(current)
      end
      NoRoot.new
    end
  end
end
