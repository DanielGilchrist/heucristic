require "yaml"

module Heucristic
  module Server
    module EntryFile
      extend self

      record Missing, reason : String

      def find(root : String) : String | Missing
        found = mains(root)
        found.is_a?(Missing) ? found : found.first
      end

      def mains(root : String) : Array(String) | Missing
        manifest = File.join(root, "shard.yml")
        return Missing.new("no shard.yml in #{root}") unless File.exists?(manifest)

        shard = YAML.parse(File.read(manifest))
        targets = from_targets(shard, root)
        return targets unless targets.empty?

        named = from_name(shard, root)
        return [named] if named

        Missing.new("shard.yml names no target and src/<name>.cr does not exist")
      rescue error : YAML::ParseException
        Missing.new("shard.yml does not parse: #{error.message}")
      end

      private def from_targets(shard : YAML::Any, root : String) : Array(String)
        mains = Array(String).new
        targets = shard["targets"]?.try(&.as_h?)
        return mains unless targets

        targets.each_value do |target|
          main = target["main"]?.try(&.as_s?)
          next unless main

          path = File.expand_path(main, root)
          mains << path if File.exists?(path) && !mains.includes?(path)
        end
        mains
      end

      private def from_name(shard : YAML::Any, root : String) : String?
        name = shard["name"]?.try(&.as_s?)
        return unless name

        path = File.join(root, "src", "#{name}.cr")
        File.exists?(path) ? path : nil
      end
    end
  end
end
