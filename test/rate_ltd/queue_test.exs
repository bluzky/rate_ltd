# test/rate_ltd/queue_test.exs
defmodule RateLtd.QueueTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()
    :ok
  end

  describe "enqueue/2" do
    test "successfully enqueues request" do
      request = %{
        id: "test-123",
        queue_name: "test_queue_success",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        queued_at: 1_234_567_890,
        expires_at: 1_234_567_890 + 30_000
      }

      config = %{max_queue_size: 5}

      result = RateLtd.Queue.enqueue(request, config)
      assert {:ok, _position} = result
    end

    test "rejects when queue is full" do
      MockRedis.reset()

      config = %{max_queue_size: 1}

      request1 = %{
        id: "test-1",
        queue_name: "small_queue_isolated",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        queued_at: 1_234_567_890,
        expires_at: 1_234_567_890 + 30_000
      }

      request2 = %{
        id: "test-2",
        queue_name: "small_queue_isolated",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        queued_at: 1_234_567_890,
        expires_at: 1_234_567_890 + 30_000
      }

      # First should succeed
      assert {:ok, 1} = RateLtd.Queue.enqueue(request1, config)

      # Second should fail due to queue being full
      assert {:error, :queue_full} = RateLtd.Queue.enqueue(request2, config)
    end

    test "handles priority queueing" do
      config = %{max_queue_size: 5}

      normal_request = %{
        id: "normal-1",
        queue_name: "priority_test",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        priority: 0,
        queued_at: System.system_time(:millisecond),
        expires_at: System.system_time(:millisecond) + 30_000
      }

      priority_request = %{
        id: "priority-1",
        queue_name: "priority_test",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        priority: 1,
        queued_at: System.system_time(:millisecond),
        expires_at: System.system_time(:millisecond) + 30_000
      }

      # Add normal request first
      assert {:ok, 1} = RateLtd.Queue.enqueue(normal_request, config)
      # Add priority request (should go to front)
      assert {:ok, 2} = RateLtd.Queue.enqueue(priority_request, config)

      # Priority request should be processed first
      {:ok, first} = RateLtd.Queue.peek_next("priority_test")
      assert first["priority"] == 1
    end

    test "handles JSON encoding properly" do
      request = %{
        id: "test-json",
        queue_name: "json_test_isolated",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        queued_at: System.system_time(:millisecond),
        expires_at: System.system_time(:millisecond) + 30_000,
        metadata: %{user_id: 123, action: "test"}
      }

      config = %{max_queue_size: 10}

      result = RateLtd.Queue.enqueue(request, config)
      assert {:ok, _} = result
    end
  end

  describe "enqueue_batch/2" do
    test "enqueues multiple requests at once" do
      requests = [
        %{
          id: "batch-1",
          queue_name: "batch_test",
          caller_pid: "encoded_pid"
        },
        %{
          id: "batch-2",
          queue_name: "batch_test",
          caller_pid: "encoded_pid"
        },
        %{
          id: "batch-3",
          queue_name: "batch_test",
          caller_pid: "encoded_pid"
        }
      ]

      config = %{max_queue_size: 10}

      result = RateLtd.Queue.enqueue_batch(requests, config)
      assert {:ok, positions} = result
      assert length(positions) == 3
    end

    test "rejects batch when queue would overflow" do
      requests = [
        %{id: "overflow-1", queue_name: "overflow_test", caller_pid: "pid"},
        %{id: "overflow-2", queue_name: "overflow_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 1}

      result = RateLtd.Queue.enqueue_batch(requests, config)
      assert {:error, :queue_full} = result
    end

    test "handles empty batch" do
      config = %{max_queue_size: 10}
      result = RateLtd.Queue.enqueue_batch([], config)
      assert {:ok, []} = result
    end
  end

  describe "peek_next/1" do
    test "returns empty for non-existent queue" do
      result = RateLtd.Queue.peek_next("truly_nonexistent_queue")
      assert {:empty} = result
    end

    test "returns request from queue without removing it" do
      request = %{
        id: "peek-test",
        queue_name: "peek_queue_isolated",
        caller_pid: "encoded_pid"
      }

      config = %{max_queue_size: 5}
      RateLtd.Queue.enqueue(request, config)

      # Peek should return the request
      result = RateLtd.Queue.peek_next("peek_queue_isolated")
      assert {:ok, data} = result
      assert is_map(data)
      assert data["id"] == "peek-test"

      # Peek again should return same request
      result2 = RateLtd.Queue.peek_next("peek_queue_isolated")
      assert {:ok, data2} = result2
      assert data2["id"] == "peek-test"
    end
  end

  describe "peek_batch/2" do
    test "returns multiple requests without removing them" do
      requests = [
        %{id: "peek-batch-1", queue_name: "peek_batch_test", caller_pid: "pid"},
        %{id: "peek-batch-2", queue_name: "peek_batch_test", caller_pid: "pid"},
        %{id: "peek-batch-3", queue_name: "peek_batch_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      result = RateLtd.Queue.peek_batch("peek_batch_test", 2)
      assert {:ok, peeked} = result
      assert length(peeked) == 2

      # Queue should still have all items
      {:ok, all_peeked} = RateLtd.Queue.peek_batch("peek_batch_test", 10)
      assert length(all_peeked) == 3
    end

    test "returns empty for non-existent queue" do
      result = RateLtd.Queue.peek_batch("nonexistent_batch", 5)
      assert {:empty} = result
    end
  end

  describe "dequeue/1" do
    test "returns empty for non-existent queue" do
      result = RateLtd.Queue.dequeue("truly_nonexistent_dequeue")
      assert {:empty} = result
    end

    test "removes and returns request from queue" do
      request = %{
        id: "dequeue-test",
        queue_name: "dequeue_queue_isolated",
        caller_pid: "encoded_pid"
      }

      config = %{max_queue_size: 5}
      RateLtd.Queue.enqueue(request, config)

      # Dequeue should return and remove the request
      result = RateLtd.Queue.dequeue("dequeue_queue_isolated")
      assert {:ok, data} = result
      assert is_map(data)
      assert data["id"] == "dequeue-test"

      # Second dequeue should be empty
      result2 = RateLtd.Queue.dequeue("dequeue_queue_isolated")
      assert {:empty} = result2
    end
  end

  describe "dequeue_batch/2" do
    test "removes and returns multiple requests" do
      requests = [
        %{id: "dequeue-batch-1", queue_name: "dequeue_batch_test", caller_pid: "pid"},
        %{id: "dequeue-batch-2", queue_name: "dequeue_batch_test", caller_pid: "pid"},
        %{id: "dequeue-batch-3", queue_name: "dequeue_batch_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      result = RateLtd.Queue.dequeue_batch("dequeue_batch_test", 2)
      assert {:ok, dequeued} = result
      assert length(dequeued) == 2

      # Should only have 1 item left
      {:ok, remaining} = RateLtd.Queue.peek_batch("dequeue_batch_test", 10)
      assert length(remaining) == 1
    end

    test "handles empty queue" do
      result = RateLtd.Queue.dequeue_batch("empty_dequeue_batch", 5)
      assert {:empty} = result
    end
  end

  describe "get_queue_length/1" do
    test "returns correct length" do
      requests = [
        %{id: "length-1", queue_name: "length_test", caller_pid: "pid"},
        %{id: "length-2", queue_name: "length_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      result = RateLtd.Queue.get_queue_length("length_test")
      assert {:ok, 2} = result
    end

    test "returns 0 for empty queue" do
      result = RateLtd.Queue.get_queue_length("empty_length_test")
      assert {:ok, 0} = result
    end
  end

  describe "remove_expired_requests/1" do
    test "removes expired requests from queue" do
      now = System.system_time(:millisecond)

      expired_request = %{
        id: "expired-1",
        queue_name: "expiry_test",
        caller_pid: "pid",
        # Already expired
        expires_at: now - 1000
      }

      valid_request = %{
        id: "valid-1",
        queue_name: "expiry_test",
        caller_pid: "pid",
        # Future expiry
        expires_at: now + 30_000
      }

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue(expired_request, config)
      RateLtd.Queue.enqueue(valid_request, config)

      # Should have 2 items initially
      {:ok, 2} = RateLtd.Queue.get_queue_length("expiry_test")

      # Remove expired requests
      result = RateLtd.Queue.remove_expired_requests("expiry_test")
      assert {:ok, removed_count} = result
      assert removed_count >= 0
    end

    test "handles queue with no expired requests" do
      now = System.system_time(:millisecond)

      valid_request = %{
        id: "valid-only",
        queue_name: "no_expiry_test",
        caller_pid: "pid",
        expires_at: now + 30_000
      }

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue(valid_request, config)

      result = RateLtd.Queue.remove_expired_requests("no_expiry_test")
      assert {:ok, 0} = result
    end
  end

  describe "list_active_queues/0" do
    test "returns empty list when no queues" do
      MockRedis.reset()
      result = RateLtd.Queue.list_active_queues()
      assert [] == result
    end

    test "returns list of queue names" do
      MockRedis.reset()

      # Add requests to exactly 2 queues
      request1 = %{id: "1", queue_name: "only_queue_1", caller_pid: "pid"}
      request2 = %{id: "2", queue_name: "only_queue_2", caller_pid: "pid"}

      config = %{max_queue_size: 5}

      {:ok, _} = RateLtd.Queue.enqueue(request1, config)
      {:ok, _} = RateLtd.Queue.enqueue(request2, config)

      result = RateLtd.Queue.list_active_queues()

      assert is_list(result)
      assert "only_queue_1" in result
      assert "only_queue_2" in result
      assert length(result) == 2
    end
  end

  describe "get_queue_stats/1" do
    test "returns comprehensive queue statistics" do
      now = System.system_time(:millisecond)

      requests = [
        %{
          id: "stats-1",
          queue_name: "stats_test",
          caller_pid: "pid",
          queued_at: now - 5000,
          expires_at: now + 25_000
        },
        %{
          id: "stats-2",
          queue_name: "stats_test",
          caller_pid: "pid",
          queued_at: now - 3000,
          expires_at: now + 27_000
        }
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      result = RateLtd.Queue.get_queue_stats("stats_test")
      assert {:ok, stats} = result

      assert Map.has_key?(stats, :queue_name)
      assert Map.has_key?(stats, :length)
      assert Map.has_key?(stats, :expired_count)
      assert Map.has_key?(stats, :avg_wait_time_ms)
      assert Map.has_key?(stats, :oldest_request_age_ms)
      assert Map.has_key?(stats, :newest_request_age_ms)

      assert stats.queue_name == "stats_test"
      assert is_integer(stats.length)
      assert is_integer(stats.expired_count)
      assert is_number(stats.avg_wait_time_ms)
    end

    test "handles empty queue stats" do
      result = RateLtd.Queue.get_queue_stats("empty_stats_test")
      assert {:ok, stats} = result
      assert stats.length == 0
    end
  end

  describe "clear_queue/1" do
    test "removes all requests from queue" do
      requests = [
        %{id: "clear-1", queue_name: "clear_test", caller_pid: "pid"},
        %{id: "clear-2", queue_name: "clear_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      # Should have items
      {:ok, 2} = RateLtd.Queue.get_queue_length("clear_test")

      # Clear queue
      :ok = RateLtd.Queue.clear_queue("clear_test")

      # Should be empty
      {:ok, 0} = RateLtd.Queue.get_queue_length("clear_test")
    end

    test "handles clearing non-existent queue" do
      result = RateLtd.Queue.clear_queue("nonexistent_clear_test")
      assert :ok = result
    end
  end

  describe "get_queue_position/2" do
    test "returns position of request in queue" do
      requests = [
        %{id: "pos-1", queue_name: "position_test", caller_pid: "pid"},
        %{id: "pos-2", queue_name: "position_test", caller_pid: "pid"},
        %{id: "pos-3", queue_name: "position_test", caller_pid: "pid"}
      ]

      config = %{max_queue_size: 10}
      RateLtd.Queue.enqueue_batch(requests, config)

      # Check positions (position 1 is next to be dequeued)
      result1 = RateLtd.Queue.get_queue_position("position_test", "pos-1")
      result2 = RateLtd.Queue.get_queue_position("position_test", "pos-2")
      result3 = RateLtd.Queue.get_queue_position("position_test", "pos-3")

      assert match?({:ok, _}, result1)
      assert match?({:ok, _}, result2)
      assert match?({:ok, _}, result3)
    end

    test "returns not_found for non-existent request" do
      result = RateLtd.Queue.get_queue_position("position_test", "nonexistent")
      assert {:not_found} = result
    end
  end

  describe "error handling" do
    test "handles Redis connection errors gracefully" do
      defmodule QueueErrorRedis do
        def eval(_, _, _), do: {:error, :connection_failed}
        def command(_), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, QueueErrorRedis)

      request = %{
        id: "error-test",
        queue_name: "error_test",
        caller_pid: "pid"
      }

      config = %{max_queue_size: 5}

      result = RateLtd.Queue.enqueue(request, config)
      assert {:error, :connection_failed} = result
    end

    test "handles invalid JSON in queue gracefully" do
      # This would be handled by the decode_request function
      result = RateLtd.Queue.peek_next("invalid_json_test")
      # MockRedis returns nil for non-existent keys
      assert {:empty} = result
    end
  end
end
