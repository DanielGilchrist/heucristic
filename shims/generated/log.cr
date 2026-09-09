class Log
  def trace(*, exception : Exception) : Nil
  end

  def trace(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def debug(*, exception : Exception) : Nil
  end

  def debug(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def info(*, exception : Exception) : Nil
  end

  def info(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def notice(*, exception : Exception) : Nil
  end

  def notice(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def warn(*, exception : Exception) : Nil
  end

  def warn(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def error(*, exception : Exception) : Nil
  end

  def error(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end

  def fatal(*, exception : Exception) : Nil
  end

  def fatal(*, exception : Exception? = nil, & : Log::Emitter -> _) : Nil
  end
end
