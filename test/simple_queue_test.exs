defmodule SimpleQueueTest do
  use ExUnit.Case
  
  setup do
    Application.ensure_all_started(:rate_ltd)
    :ok
  end

  test "can create a queued request" do
    request = RateLtd.QueuedRequest.new("test:queue", "test:key", fn -> :test end)
    assert request.queue_name == "test:queue"
    assert request.rate_limit_key == "test:key"
    assert is_function(request.function)
    assert is_binary(request.id)
  end

  test "can serialize and deserialize request" do
    request = RateLtd.QueuedRequest.new("test:queue", "test:key", fn -> :test end)
    serialized = RateLtd.QueuedRequest.serialize(request)
    assert is_binary(serialized)
    
    {:ok, deserialized} = RateLtd.QueuedRequest.deserialize(serialized)
    assert deserialized.queue_name == request.queue_name
    assert deserialized.rate_limit_key == request.rate_limit_key
    assert deserialized.id == request.id
  end
end
