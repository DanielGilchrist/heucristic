class HTTP::Client
  def self.new(uri : URI, tls : TLSContext = nil, & : HTTP::Client -> U) : U forall U
  end

  def self.new(host : String, port = nil, tls : TLSContext = nil, & : HTTP::Client -> U) : U forall U
  end
end
