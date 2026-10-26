class Log
  def self.setup(*, builder : Log::Builder = Log.builder, & : Log::Configuration -> U) : U forall U
  end

  def self.setup(level : Log::Severity = Log::Severity::Info, backend : Log::Backend = IOBackend.new, *, builder : Log::Builder = Log.builder) : Nil
  end
end
