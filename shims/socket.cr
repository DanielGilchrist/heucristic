class Socket
  def keepalive=(val : Bool) : Bool
  end
end

class IPSocket
  def close : Nil
  end
end

class TCPSocket
  def tcp_keepalive_idle=(val : Int) : typeof(val)
  end

  def tcp_keepalive_interval=(val : Int) : typeof(val)
  end

  def tcp_keepalive_count=(val : Int) : typeof(val)
  end
end

struct Socket::IPAddress
  def self.new(address : String, port : Int32) : self
  end
end
