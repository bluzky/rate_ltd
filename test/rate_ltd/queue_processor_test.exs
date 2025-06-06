# test/rate_ltd/queue_processor_test.exs
defmodule RateLtd.QueueProcessorTest do
  use ExUnit.Case, async: false

  setup do
    # Start mock Redis
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()

    # Configure test environment
    Application.put_env(:rate_ltd, :defaults, limit: 5, window_ms: 1000)

    Application.put_env(:rate_ltd, :configs, %{
      "test_api" => %{limit: 2, window_ms: 1000}
    })

    pid = Process.whereis(RateLtd.QueueProcessor)
    if pid, do: GenServer.stop(pid, :normal, 1000)

    :ok
  end

  describe "QueueProcessor GenServer" do
    test "starts successfully" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link([])
      assert Process.alive?(pid)
    end

    test "schedules periodic queue checking" do
      {:ok, _pid} = RateLtd.QueueProcessor.start_link([])

      # The process should be alive and scheduling work
      # We can't easily test the timer without making it faster
      # So we just verify it starts without crashing
      Process.sleep(100)

      # Process should still be alive
      assert Process.whereis(RateLtd.QueueProcessor) |> Process.alive?()
    end
  end

  describe "process_ready_requests/0 (private function testing via message)" do
    test "handles empty queues gracefully" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link([])

      # Send the check message manually
      send(pid, :check_queues)

      # Should not crash
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "processes queued requests when rate limit allows" do
      # This is a more complex integration test
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create a test process that will receive the signal
      test_pid = self()

      # Mock a queued request
      request = %{
        "id" => "test-123",
        "rate_limit_key" => "test_api",
        "caller_pid" => :erlang.term_to_binary(test_pid) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      # Add request to queue manually (using mock Redis)
      queue_key = "rate_ltd:queue:test_queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      # Trigger queue processing manually
      send(processor_pid, :check_queues)

      # Should not crash the processor
      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "request expiration handling" do
    test "removes expired requests" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create an expired request
      expired_request = %{
        "id" => "expired-123",
        "rate_limit_key" => "test_api",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        # Already expired
        "expires_at" => System.system_time(:millisecond) - 1000
      }

      # Add to queue
      queue_key = "rate_ltd:queue:expired_test"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(expired_request)])

      # Process should handle expired request gracefully
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "dead process handling" do
    test "handles dead caller processes" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create a process and kill it
      dead_pid = spawn(fn -> :ok end)
      Process.exit(dead_pid, :kill)
      # Ensure process is dead
      Process.sleep(10)

      # Create request with dead PID
      request = %{
        "id" => "dead-caller-123",
        "rate_limit_key" => "test_api",
        "caller_pid" => :erlang.term_to_binary(dead_pid) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      # Add to queue
      queue_key = "rate_ltd:queue:dead_caller_test"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      # Should handle dead process gracefully
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "error handling" do
    test "handles invalid JSON gracefully" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Add invalid JSON to queue
      queue_key = "rate_ltd:queue:invalid_json_test"
      MockRedis.command(["LPUSH", queue_key, "invalid json"])

      # Should not crash
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "handles missing request fields" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Request missing required fields
      incomplete_request = %{"id" => "incomplete"}

      queue_key = "rate_ltd:queue:incomplete_test"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(incomplete_request)])

      # Should handle gracefully
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end
end
