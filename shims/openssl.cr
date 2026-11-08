abstract class OpenSSL::SSL::Context
  def add_options(options : OpenSSL::SSL::Options) : LibSSL::Options
  end

  def remove_options(options : OpenSSL::SSL::Options) : LibSSL::Options
  end
end

abstract class OpenSSL::SSL::Context
  def certificate_chain=(file_path : String) : Nil
  end

  def private_key=(file_path : String) : Nil
  end

  def ciphers=(ciphers : String) : String
  end

  def verify_mode=(mode : OpenSSL::SSL::VerifyMode) : Nil
  end
end

abstract class OpenSSL::SSL::Context
  def ca_certificates=(file_path : String) : Nil
  end

  def ca_certificates_path=(dir_path : String) : Nil
  end
end
