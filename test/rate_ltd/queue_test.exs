# test/rate_ltd/queue_test.exs
defmodule RateLtd.QueueTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)

    # Force clear all Redis data before each test
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
      # Clear state at start of test
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

    test "handles JSON encoding" do
      request = %{
        id: "test-json",
        queue_name: "json_test_isolated",
        rate_limit_key: "test_api",
        caller_pid: "encoded_pid",
        queued_at: System.system_time(:millisecond),
        expires_at: System.system_time(:millisecond) + 30_000
      }

      config = %{max_queue_size: 10}

      # Should not crash on JSON encoding
      result = RateLtd.Queue.enqueue(request, config)
      assert {:ok, _} = result
    end
  end

  describe "peek_next/1" do
    test "returns empty for non-existent queue" do
      result = RateLtd.Queue.peek_next("truly_nonexistent_queue")
      assert {:empty} = result
    end

    test "returns request from queue without removing it" do
      # Add a request first
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

      # Peek again should return same request
      result2 = RateLtd.Queue.peek_next("peek_queue_isolated")
      assert {:ok, _data} = result2
    end
  end

  describe "dequeue/1" do
    test "returns empty for non-existent queue" do
      result = RateLtd.Queue.dequeue("truly_nonexistent_dequeue")
      assert {:empty} = result
    end

    test "removes and returns request from queue" do
      # Add a request first
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

      # Second dequeue should be empty
      result2 = RateLtd.Queue.dequeue("dequeue_queue_isolated")
      assert {:empty} = result2
    end
  end

  describe "list_active_queues/0" do
    test "returns empty list when no queues" do
      # Force completely clean state - clear all data
      MockRedis.reset()

      # Verify no queues exist
      result = RateLtd.Queue.list_active_queues()

      # Debug output if test fails
      if result != [] do
        IO.puts("DEBUG: Expected empty list but got: #{inspect(result)}")
        IO.puts("DEBUG: MockRedis state: #{inspect(MockRedis.debug_state())}")
      end

      assert [] == result
    end

    test "returns list of queue names" do
      # Start with completely clean state
      MockRedis.reset()

      # Verify we start clean
      initial_queues = RateLtd.Queue.list_active_queues()

      assert [] == initial_queues,
             "Test should start with empty queues, but found: #{inspect(initial_queues)}"

      # Add requests to exactly 2 queues
      request1 = %{id: "1", queue_name: "only_queue_1", caller_pid: "pid"}
      request2 = %{id: "2", queue_name: "only_queue_2", caller_pid: "pid"}

      config = %{max_queue_size: 5}

      # Add both requests
      {:ok, _} = RateLtd.Queue.enqueue(request1, config)
      {:ok, _} = RateLtd.Queue.enqueue(request2, config)

      # Check results
      result = RateLtd.Queue.list_active_queues()

      # Debug output if test fails
      if length(result) != 2 do
        IO.puts("DEBUG: Expected 2 queues but got #{length(result)}: #{inspect(result)}")
        IO.puts("DEBUG: MockRedis state: #{inspect(MockRedis.debug_state())}")
      end

      assert is_list(result)
      assert "only_queue_1" in result
      assert "only_queue_2" in result

      assert length(result) == 2,
             "Expected exactly 2 queues, but got #{length(result)}: #{inspect(result)}"
    end
  end
end
