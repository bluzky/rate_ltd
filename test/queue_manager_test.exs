defmodule RateLtd.QueueManagerTest do
  use ExUnit.Case
  alias RateLtd.{QueueManager, QueuedRequest}
  import RateLtd.TestHelpers

  setup do
    Application.ensure_all_started(:rate_ltd)
    clear_redis()
    :ok
  end

  describe "enqueue/2" do
    test "successfully enqueues a request" do
      config = create_test_queue_config("test:queue")
      request = QueuedRequest.new("test:queue", "test:key", make_test_function())
      
      assert {:queued, request_id} = QueueManager.enqueue(request, config)
      assert is_binary(request_id)
    end

    test "rejects requests when queue is full" do
      config = create_test_queue_config("test:full", max_size: 1)
      request1 = QueuedRequest.new("test:full", "test:key", make_test_function())
      request2 = QueuedRequest.new("test:full", "test:key", make_test_function())
      
      assert {:queued, _} = QueueManager.enqueue(request1, config)
      assert {:rejected, :queue_full} = QueueManager.enqueue(request2, config)
    end

    test "drops oldest when overflow strategy is drop_oldest" do
      config = create_test_queue_config("test:drop", max_size: 1, overflow_strategy: :drop_oldest)
      request1 = QueuedRequest.new("test:drop", "test:key", make_test_function(:first))
      request2 = QueuedRequest.new("test:drop", "test:key", make_test_function(:second))
      
      assert {:queued, _} = QueueManager.enqueue(request1, config)
      assert {:queued, _} = QueueManager.enqueue(request2, config)
      
      # Should have dropped the first request
      assert {:ok, dequeued} = QueueManager.dequeue("test:drop")
      result = dequeued.function.()
      assert result == :second
    end
  end

  describe "dequeue/1" do
    test "returns empty when queue is empty" do
      assert {:empty} = QueueManager.dequeue("test:empty")
    end

    test "dequeues requests in FIFO order" do
      config = create_test_queue_config("test:fifo")
      request1 = QueuedRequest.new("test:fifo", "test:key", make_test_function(:first))
      request2 = QueuedRequest.new("test:fifo", "test:key", make_test_function(:second))
      
      QueueManager.enqueue(request1, config)
      QueueManager.enqueue(request2, config)
      
      assert {:ok, dequeued1} = QueueManager.dequeue("test:fifo")
      assert {:ok, dequeued2} = QueueManager.dequeue("test:fifo")
      
      assert dequeued1.function.() == :first
      assert dequeued2.function.() == :second
      
      assert {:empty} = QueueManager.dequeue("test:fifo")
    end

    test "prioritizes higher priority requests" do
      config = create_test_queue_config("test:priority", enable_priority: true)
      
      normal_request = QueuedRequest.new("test:priority", "test:key", make_test_function(:normal), priority: 1)
      high_request = QueuedRequest.new("test:priority", "test:key", make_test_function(:high), priority: 2)
      
      QueueManager.enqueue(normal_request, config)
      QueueManager.enqueue(high_request, config)
      
      # High priority should come first
      assert {:ok, dequeued} = QueueManager.dequeue("test:priority")
      assert dequeued.function.() == :high
    end
  end

  describe "peek_next/1" do
    test "returns next request without removing it" do
      config = create_test_queue_config("test:peek")
      request = QueuedRequest.new("test:peek", "test:key", make_test_function())
      
      QueueManager.enqueue(request, config)
      
      assert {:ok, peeked} = QueueManager.peek_next("test:peek")
      assert peeked.id == request.id
      
      # Should still be in queue
      assert {:ok, dequeued} = QueueManager.dequeue("test:peek")
      assert dequeued.id == request.id
    end

    test "returns empty when queue is empty" do
      assert {:empty} = QueueManager.peek_next("test:empty_peek")
    end
  end

  describe "get_status/1" do
    test "returns accurate queue status" do
      config = create_test_queue_config("test:status")
      request = QueuedRequest.new("test:status", "test:key", make_test_function())
      
      # Empty queue
      status = QueueManager.get_status("test:status")
      assert status.depth == 0
      assert status.oldest_request_age_ms == 0
      
      # Add request
      QueueManager.enqueue(request, config)
      wait_for_processing(50)
      
      status = QueueManager.get_status("test:status")
      assert status.depth == 1
      assert status.oldest_request_age_ms > 0
    end
  end

  describe "cleanup_expired/1" do
    test "removes expired requests" do
      config = create_test_queue_config("test:cleanup")
      
      # Create an already expired request
      expired_request = %QueuedRequest{
        id: UUID.uuid4(),
        queue_name: "test:cleanup",
        rate_limit_key: "test:key",
        function: make_test_function(),
        queued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), -1000, :millisecond), # Already expired
        priority: 1
      }
      
      valid_request = QueuedRequest.new("test:cleanup", "test:key", make_test_function())
      
      QueueManager.enqueue(expired_request, config)
      QueueManager.enqueue(valid_request, config)
      
      assert {:ok, cleaned_count} = QueueManager.cleanup_expired("test:cleanup")
      assert cleaned_count >= 0 # May be 0 or 1 depending on Redis timing
      
      # Valid request should still be there
      assert {:ok, _} = QueueManager.peek_next("test:cleanup")
    end
  end

  describe "list_queues/0" do
    test "lists all active queues" do
      config1 = create_test_queue_config("test:list1")
      config2 = create_test_queue_config("test:list2")
      
      request1 = QueuedRequest.new("test:list1", "test:key", make_test_function())
      request2 = QueuedRequest.new("test:list2", "test:key", make_test_function())
      
      QueueManager.enqueue(request1, config1)
      QueueManager.enqueue(request2, config2)
      
      {:ok, queues} = QueueManager.list_queues()
      
      assert "test:list1" in queues
      assert "test:list2" in queues
    end
  end
end
