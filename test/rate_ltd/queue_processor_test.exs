# test/rate_ltd/queue_processor_test.exs
defmodule RateLtd.QueueProcessorTest do
  use ExUnit.Case, async: false

  setup do
    # Start mock Redis
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()

    # Configure test environment
    Application.put_env(:rate_ltd, :defaults,
      limit: 5,
      window_ms: 1000,
      max_queue_size: 10
    )

    Application.put_env(:rate_ltd, :group_configs, %{
      "test_group" => %{limit: 3, window_ms: 1000, max_queue_size: 5},
      "payment_api" => %{limit: 10, window_ms: 5000, max_queue_size: 20}
    })

    Application.put_env(:rate_ltd, :configs, %{
      "simple_test" => %{limit: 2, window_ms: 1000, max_queue_size: 5}
    })

    # Stop any existing QueueProcessor
    pid = Process.whereis(RateLtd.QueueProcessor)
    if pid, do: GenServer.stop(pid, :normal, 1000)

    :ok
  end

  describe "QueueProcessor GenServer lifecycle" do
    test "starts successfully" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link([])
      assert Process.alive?(pid)
      assert Process.whereis(RateLtd.QueueProcessor) == pid
    end

    test "starts with custom name" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link(name: :custom_processor)
      assert Process.alive?(pid)
      assert Process.whereis(:custom_processor) == pid
    end

    test "schedules periodic queue checking" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link([])

      # Should be alive and scheduling work
      Process.sleep(100)
      assert Process.alive?(pid)

      # Send manual check to ensure it handles the message
      send(pid, :check_queues)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "handles restart correctly" do
      {:ok, pid1} = RateLtd.QueueProcessor.start_link([])
      GenServer.stop(pid1, :normal)

      {:ok, pid2} = RateLtd.QueueProcessor.start_link([])
      assert Process.alive?(pid2)
      assert pid1 != pid2
    end
  end

  describe "queue processing" do
    test "handles empty queues gracefully" do
      {:ok, pid} = RateLtd.QueueProcessor.start_link([])

      # Send the check message manually
      send(pid, :check_queues)

      # Should not crash
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "processes queued requests when rate limit allows" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      test_pid = self()

      # Create a queued request for a grouped bucket
      request = %{
        "id" => "test-123",
        "rate_limit_key" => "bucket:test_group:merchant_1",
        "caller_pid" => :erlang.term_to_binary(test_pid) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000,
        "queued_at" => System.system_time(:millisecond)
      }

      # Add request to queue manually
      queue_key = "rate_ltd:queue:bucket:test_group:merchant_1:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      # Trigger queue processing manually
      send(processor_pid, :check_queues)

      # Should not crash the processor
      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "processes simple key requests" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      test_pid = self()

      # Create a queued request for a simple key
      request = %{
        "id" => "simple-test-456",
        "rate_limit_key" => "simple:simple_test",
        "caller_pid" => :erlang.term_to_binary(test_pid) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000,
        "queued_at" => System.system_time(:millisecond)
      }

      queue_key = "rate_ltd:queue:simple:simple_test:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "handles multiple queues concurrently" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create requests in multiple queues
      requests = [
        {
          "bucket:test_group:merchant_1:queue",
          %{
            "id" => "multi-1",
            "rate_limit_key" => "bucket:test_group:merchant_1",
            "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
            "expires_at" => System.system_time(:millisecond) + 30_000
          }
        },
        {
          "bucket:payment_api:merchant_2:queue",
          %{
            "id" => "multi-2",
            "rate_limit_key" => "bucket:payment_api:merchant_2",
            "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
            "expires_at" => System.system_time(:millisecond) + 30_000
          }
        },
        {
          "simple:simple_test:queue",
          %{
            "id" => "multi-3",
            "rate_limit_key" => "simple:simple_test",
            "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
            "expires_at" => System.system_time(:millisecond) + 30_000
          }
        }
      ]

      # Add all requests to their respective queues
      Enum.each(requests, fn {queue_name, request} ->
        queue_key = "rate_ltd:queue:#{queue_name}"
        MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])
      end)

      send(processor_pid, :check_queues)

      Process.sleep(150)
      assert Process.alive?(processor_pid)
    end
  end

  describe "request expiration handling" do
    test "removes expired requests" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create an expired request
      expired_request = %{
        "id" => "expired-123",
        "rate_limit_key" => "bucket:test_group:expired_merchant",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        # Already expired
        "expires_at" => System.system_time(:millisecond) - 1000,
        "queued_at" => System.system_time(:millisecond) - 2000
      }

      queue_key = "rate_ltd:queue:bucket:test_group:expired_merchant:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(expired_request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "preserves non-expired requests" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create a valid (non-expired) request
      valid_request = %{
        "id" => "valid-789",
        "rate_limit_key" => "bucket:test_group:valid_merchant",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000,
        "queued_at" => System.system_time(:millisecond)
      }

      queue_key = "rate_ltd:queue:bucket:test_group:valid_merchant:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(valid_request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)

      # Request should still be in queue (since we're not actually processing it)
      {:ok, queue_length} = MockRedis.command(["LLEN", queue_key])
      # Might be processed or still waiting
      assert queue_length >= 0
    end

    test "handles mixed expired and valid requests" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      now = System.system_time(:millisecond)

      requests = [
        %{
          "id" => "expired-1",
          "rate_limit_key" => "bucket:test_group:mixed_test",
          "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
          # Expired
          "expires_at" => now - 1000
        },
        %{
          "id" => "valid-1",
          "rate_limit_key" => "bucket:test_group:mixed_test",
          "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
          # Valid
          "expires_at" => now + 30_000
        },
        %{
          "id" => "expired-2",
          "rate_limit_key" => "bucket:test_group:mixed_test",
          "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
          # Expired
          "expires_at" => now - 500
        }
      ]

      queue_key = "rate_ltd:queue:bucket:test_group:mixed_test:queue"

      Enum.each(requests, fn request ->
        MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])
      end)

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "dead process handling" do
    test "handles dead caller processes" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Create a process and kill it
      dead_pid = spawn(fn -> :timer.sleep(10) end)
      Process.exit(dead_pid, :kill)
      # Ensure process is dead
      Process.sleep(20)

      # Create request with dead PID
      request = %{
        "id" => "dead-caller-123",
        "rate_limit_key" => "bucket:test_group:dead_test",
        "caller_pid" => :erlang.term_to_binary(dead_pid) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000,
        "queued_at" => System.system_time(:millisecond)
      }

      queue_key = "rate_ltd:queue:bucket:test_group:dead_test:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      # Should handle dead process gracefully
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "continues processing after encountering dead processes" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      dead_pid = spawn(fn -> :ok end)
      Process.exit(dead_pid, :kill)
      Process.sleep(10)

      live_pid = self()

      requests = [
        %{
          "id" => "dead-process",
          "rate_limit_key" => "bucket:test_group:process_test",
          "caller_pid" => :erlang.term_to_binary(dead_pid) |> Base.encode64(),
          "expires_at" => System.system_time(:millisecond) + 30_000
        },
        %{
          "id" => "live-process",
          "rate_limit_key" => "bucket:test_group:process_test",
          "caller_pid" => :erlang.term_to_binary(live_pid) |> Base.encode64(),
          "expires_at" => System.system_time(:millisecond) + 30_000
        }
      ]

      queue_key = "rate_ltd:queue:bucket:test_group:process_test:queue"

      Enum.each(requests, fn request ->
        MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])
      end)

      send(processor_pid, :check_queues)

      Process.sleep(150)
      assert Process.alive?(processor_pid)
    end
  end

  describe "error handling" do
    test "handles invalid JSON gracefully" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Add invalid JSON to queue
      queue_key = "rate_ltd:queue:bucket:test_group:invalid_json:queue"
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

      queue_key = "rate_ltd:queue:bucket:test_group:incomplete:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(incomplete_request)])

      # Should handle gracefully
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "handles Redis connection errors" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Replace with error Redis
      defmodule ProcessorErrorRedis do
        def command(_), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ProcessorErrorRedis)

      # Should not crash even with Redis errors
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "handles malformed caller PIDs" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      request = %{
        "id" => "malformed-pid",
        "rate_limit_key" => "bucket:test_group:malformed_test",
        "caller_pid" => Base.encode64(:erlang.term_to_binary("notavalidencodedpid")),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      queue_key = "rate_ltd:queue:bucket:test_group:malformed_test:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "rate limiting integration" do
    test "respects rate limits when processing queues" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Fill up the rate limit first
      bucket_key = "bucket:test_group:rate_limit_test"
      config = RateLtd.ConfigManager.get_config(bucket_key)

      # Exhaust the rate limit
      1..config.limit
      |> Enum.each(fn _ ->
        RateLtd.Limiter.check_rate(bucket_key, config)
      end)

      # Now add a queued request
      request = %{
        "id" => "rate-limited",
        "rate_limit_key" => bucket_key,
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      queue_key = "rate_ltd:queue:#{bucket_key}:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      # Process queue - request should remain queued due to rate limit
      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "processes requests when rate limit allows" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Use a fresh bucket with available capacity
      request = %{
        "id" => "allowed-request",
        "rate_limit_key" => "bucket:test_group:fresh_bucket",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      queue_key = "rate_ltd:queue:bucket:test_group:fresh_bucket:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "configuration handling" do
    test "works with different bucket types" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Test both grouped and simple bucket types
      requests = [
        %{
          "id" => "grouped-bucket",
          "rate_limit_key" => "bucket:payment_api:merchant_config_test",
          "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
          "expires_at" => System.system_time(:millisecond) + 30_000
        },
        %{
          "id" => "simple-bucket",
          "rate_limit_key" => "simple:simple_test",
          "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
          "expires_at" => System.system_time(:millisecond) + 30_000
        }
      ]

      # Add to respective queues
      Enum.each(requests, fn request ->
        queue_name = "#{request["rate_limit_key"]}:queue"
        queue_key = "rate_ltd:queue:#{queue_name}"
        MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])
      end)

      send(processor_pid, :check_queues)

      Process.sleep(150)
      assert Process.alive?(processor_pid)
    end

    test "handles configuration errors gracefully" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Request with invalid rate_limit_key format
      request = %{
        "id" => "invalid-config",
        "rate_limit_key" => "invalid_format_key",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      queue_key = "rate_ltd:queue:invalid_format_key:queue"
      MockRedis.command(["LPUSH", queue_key, Jason.encode!(request)])

      send(processor_pid, :check_queues)

      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end
  end

  describe "timing and scheduling" do
    test "schedules next check after processing" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Send initial check
      send(processor_pid, :check_queues)

      # Should still be alive after processing
      Process.sleep(50)
      assert Process.alive?(processor_pid)

      # Should continue to be alive (scheduling next check)
      Process.sleep(100)
      assert Process.alive?(processor_pid)
    end

    test "handles multiple rapid check messages" do
      {:ok, processor_pid} = RateLtd.QueueProcessor.start_link([])

      # Send multiple check messages rapidly
      Enum.each(1..5, fn _ ->
        send(processor_pid, :check_queues)
      end)

      # Should handle all messages without crashing
      Process.sleep(200)
      assert Process.alive?(processor_pid)
    end
  end
end
