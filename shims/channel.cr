class Channel(T)
  protected def send_internal(value : T) : Channel::DeliveryState
  end

  protected def receive_internal : Tuple(Channel::DeliveryState, T | Channel::UseDefault)
  end
end
