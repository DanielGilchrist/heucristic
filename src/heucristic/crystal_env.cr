module Heucristic
  module CrystalEnv
    extend self

    record Unavailable, reason : String

    def source_paths(root : String) : Array(String) | Unavailable
      raw = crystal_path
      return raw if raw.is_a?(Unavailable)

      raw.split(':').reject(&.empty?).map { |entry| File.expand_path(entry, root) }
    end

    private def crystal_path : String | Unavailable
      output = IO::Memory.new
      status = Process.run(
        "crystal", {"env", "CRYSTAL_PATH"}, output: output, error: Process::Redirect::Close
      )
      return Unavailable.new("crystal env exited #{status.exit_code}") unless status.success?

      output.to_s.strip
    rescue error : File::NotFoundError
      Unavailable.new("crystal not found: #{error.message}")
    rescue error : IO::Error
      Unavailable.new(error.message || error.class.name)
    end
  end
end
