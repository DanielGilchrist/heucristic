class HTTP::Client
  def get(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def get(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.get(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.get(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def get(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def get(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def get(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def get(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.get(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.get(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def post(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def post(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.post(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.post(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def post(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def post(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def post(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def post(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.post(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.post(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def put(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def put(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.put(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.put(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def put(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def put(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def put(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def put(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.put(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.put(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def head(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def head(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.head(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.head(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def head(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def head(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def head(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def head(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.head(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.head(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def delete(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def delete(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.delete(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.delete(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def delete(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def delete(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def delete(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def delete(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.delete(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.delete(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def patch(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def patch(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.patch(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.patch(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def patch(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def patch(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def patch(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def patch(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.patch(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.patch(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end

  def options(path, headers : HTTP::Headers? = nil, body : BodyType = nil) : HTTP::Client::Response
  end

  def options(path, headers : HTTP::Headers? = nil, body : BodyType = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.options(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil) : HTTP::Client::Response
  end

  def self.options(url : String | URI, headers : HTTP::Headers? = nil, body : BodyType = nil, tls : TLSContext = nil, & : HTTP::Client::Response -> U) : U forall U
  end

  def options(path, headers : HTTP::Headers? = nil, *, form : String | IO) : HTTP::Client::Response
  end

  def options(path, headers : HTTP::Headers? = nil, *, form : String | IO, & : HTTP::Client::Response -> U) : U forall U
  end

  def options(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple) : HTTP::Client::Response
  end

  def options(path, headers : HTTP::Headers? = nil, *, form : Hash(String, String) | NamedTuple, & : HTTP::Client::Response -> U) : U forall U
  end

  def self.options(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash) : HTTP::Client::Response
  end

  def self.options(url, headers : HTTP::Headers? = nil, tls : TLSContext = nil, *, form : String | IO | Hash, & : HTTP::Client::Response -> U) : U forall U
  end
end
