abstract class OpenSSL::SSL::Context
  def add_options(options : OpenSSL::SSL::Options) : LibSSL::Options
  end

  def remove_options(options : OpenSSL::SSL::Options) : LibSSL::Options
  end
end
