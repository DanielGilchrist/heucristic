require "yaml"

module Heucristic
  module Server
    module EntryFile
      extend self

      record Missing, reason : String

      def find(root : String) : String | Missing
        manifest = File.join(root, "shard.yml")
        return Missing.new("no shard.yml in #{root}") unless File.exists?(manifest)

        shard = YAML.parse(File.read(manifest))
        from_targets(shard, root) || from_name(shard, root) ||
          Missing.new("shard.yml names no target and src/<name>.cr does not exist")
      rescue error : YAML::ParseException
        Missing.new("shard.yml does not parse: #{error.message}")
      end

      private def from_targets(shard : YAML::Any, root : String) : String?
        targets = shard["targets"]?.try(&.as_h?)
        return unless targets

        targets.each_value do |target|
          main = target["main"]?.try(&.as_s?)
          next unless main

          path = File.expand_path(main, root)
          return path if File.exists?(path)
        end
        nil
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
