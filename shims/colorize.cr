module Colorize::ObjectExtensions
  def colorize(fore : UInt8) : Colorize::Object(self)
  end

  def colorize(r : UInt8, g : UInt8, b : UInt8) : Colorize::Object(self)
  end

  def colorize(fore : Color) : Colorize::Object(self)
  end

  def colorize(fore : Symbol) : Colorize::Object(self)
  end
end
