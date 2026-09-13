module WebMock
  def stub(method, uri) : WebMock::Stub
  end
end

struct WebMock::StubRegistry
  def stub(method, uri) : WebMock::Stub
  end
end

class WebMock::Stub
  def with(query : Hash(String, String)? = nil, body : String? = nil, headers = nil) : WebMock::Stub
  end

  def to_return(body : String? = "", status = 200, headers = nil) : WebMock::Stub
  end

  def to_return(body_io : IO, status = 200, headers = nil) : WebMock::Stub
  end

  def to_return(&block : HTTP::Request -> HTTP::Client::Response) : WebMock::Stub
  end
end
