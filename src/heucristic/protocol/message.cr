require "json"

module Heucristic
  module Protocol
    alias Id = Int64 | String

    record Request, id : Id, method : String, params : JSON::Any?
    record Notification, method : String, params : JSON::Any?
    record Response, id : Id?, result : JSON::Any?, error : JSON::Any?

    alias Message = Request | Notification | Response
  end
end
