class OptionParser
  def on(flag : String, description : String, &block : String ->) : OptionParser::Handler
  end

  def on(short_flag : String, long_flag : String, description : String, &block : String ->) : OptionParser::Handler
  end

  def invalid_option(&@invalid_option : String ->) : Proc(String, Nil)
  end
end
