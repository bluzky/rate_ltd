# test/rate_ltd_test.exs
defmodule RateLtdTest do
  use ExUnit.Case, async: false
  doctest RateLtd

  alias RateLtd.TestHelper

  setup do
    # Configure test environment
    Application.put_env(:rate_ltd, :defaults, limit: 100, window_ms: 60_000, max_queue_size: 1000)

    Application.put_env(:rate_ltd, :configs, %{
      "test_key" => %{limit: 10, window_ms: 60_000, max_queue_size: 100}
    })

    Application.put_env(:rate_ltd, :group_configs, %{
      "api" => %{limit: 1000, window_ms: 60_000, max_queue_size: 500}
    })

    Application.put_env(:rate_ltd, :api_key_configs, %{
      "api:premium_user" => %{limit: 5000, window_ms: 60_000, max_queue_size: 1000}
    })

    Application.put_env(:rate_ltd, :queue_check_interval, 100)

    # Clear Redis and local queue before each test
    TestHelper.clear_redis()
    TestHelper.clear_local_queue()

    # Start queue processor for tests
    RateLtd.QueueProcessor.start_link([])

    :ok
  end

  describe "request/2" do
    test "executes function when rate limit allows" do
      key = TestHelper.unique_key("request_test")

      result = RateLtd.request(key, fn -> "success" end)
      assert {:ok, "success"} = result
    end

    test "handles function errors gracefully" do
      key = TestHelper.unique_key("error_test")

      result = RateLtd.request(key, fn -> raise "test error" end)
      assert {:error, {:function_error, %RuntimeError{message: "test error"}}} = result
    end

    test "works with grouped bucket tuples" do
      result = RateLtd.request({"premium_user", "api"}, fn -> "grouped success" end)
      assert {:ok, "grouped success"} = result
    end

    test "respects rate limits and uses local queue" do
      key = TestHelper.unique_key("rate_limit_test")

      # Configure very low limit for testing
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 2, window_ms: 5000, max_queue_size: 100}
      })

      # First requests should succeed
      assert {:ok, "result1"} = RateLtd.request(key, fn -> "result1" end)
      assert {:ok, "result2"} = RateLtd.request(key, fn -> "result2" end)

      # Third request should be queued locally
      task =
        Task.async(fn ->
          RateLtd.request(key, fn -> "result3" end, timeout_ms: 9000)
        end)

      # Verify request is in local queue
      Process.sleep(100)
      assert RateLtd.LocalQueue.count_local_pending() > 0

      # Should eventually succeed when rate limit allows
      result = Task.await(task, 10000)
      assert {:ok, "result3"} = result
    end
  end

  describe "request/3 with options" do
    test "respects custom timeout" do
      key = TestHelper.unique_key("timeout_test")

      result = RateLtd.request(key, fn -> "success" end, timeout_ms: 5000)
      assert {:ok, "success"} = result
    end

    test "respects max_retries option" do
      key = TestHelper.unique_key("retry_test")

      result = RateLtd.request(key, fn -> "success" end, max_retries: 1)
      assert {:ok, "success"} = result
    end

    test "times out when queued too long" do
      key = TestHelper.unique_key("queue_timeout_test")

      # Configure very low limit to force queueing
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 0, window_ms: 60_000, max_queue_size: 100}
      })

      result = RateLtd.request(key, fn -> "should timeout" end, timeout_ms: 100)
      assert {:error, :timeout} = result
    end

    test "returns queue_full when local queue is full" do
      key = TestHelper.unique_key("queue_full_test")

      # Configure very small queue and no rate limit
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 0, window_ms: 60_000, max_queue_size: 2}
      })

      # Fill up the queue
      task1 =
        Task.async(fn ->
          RateLtd.request(key, fn -> "result1" end, timeout_ms: 5000)
        end)

      task2 =
        Task.async(fn ->
          RateLtd.request(key, fn -> "result2" end, timeout_ms: 5000)
        end)

      Process.sleep(100)

      # Third request should fail with queue_full
      result = RateLtd.request(key, fn -> "result3" end, timeout_ms: 100)
      assert {:error, :queue_full} = result

      # Cleanup
      Task.shutdown(task1, :brutal_kill)
      Task.shutdown(task2, :brutal_kill)
    end
  end

  describe "local queue operations" do
    test "local queue enqueue and dequeue work correctly" do
      config = %{max_queue_size: 10}

      request = %{
        "id" => "test-123",
        "rate_limit_key" => "test:key",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      # Test enqueue
      assert {:ok, 1} = RateLtd.LocalQueue.enqueue(request, config)
      assert RateLtd.LocalQueue.count_local_pending() == 1

      # Test peek
      assert {:ok, peeked_request} = RateLtd.LocalQueue.peek_next()
      assert peeked_request["id"] == "test-123"

      # Test dequeue
      assert {:ok, dequeued_request} = RateLtd.LocalQueue.dequeue()
      assert dequeued_request["id"] == "test-123"
      assert RateLtd.LocalQueue.count_local_pending() == 0

      # Test empty queue
      assert {:empty} = RateLtd.LocalQueue.peek_next()
      assert {:empty} = RateLtd.LocalQueue.dequeue()
    end

    test "local queue respects max size" do
      config = %{max_queue_size: 2}

      request1 = %{
        "id" => "test-1",
        "rate_limit_key" => "test:key",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      request2 = Map.put(request1, "id", "test-2")
      request3 = Map.put(request1, "id", "test-3")

      # Fill up queue
      assert {:ok, 1} = RateLtd.LocalQueue.enqueue(request1, config)
      assert {:ok, 2} = RateLtd.LocalQueue.enqueue(request2, config)

      # Third should fail
      assert {:error, :queue_full} = RateLtd.LocalQueue.enqueue(request3, config)
    end

    test "redis pending counters are updated correctly" do
      config = %{max_queue_size: 10}

      request = %{
        "id" => "test-counter",
        "rate_limit_key" => "test:counter:key",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      # Enqueue should increment counter
      {:ok, _} = RateLtd.LocalQueue.enqueue(request, config)

      pending_key = "rate_ltd:pending:test:counter:key"
      {:ok, count_str} = RateLtd.Redis.command(["GET", pending_key])
      assert String.to_integer(count_str) == 1

      # Dequeue should decrement counter
      {:ok, _} = RateLtd.LocalQueue.dequeue()

      {:ok, count_str} = RateLtd.Redis.command(["GET", pending_key])
      assert count_str == "0" or is_nil(count_str)
    end
  end

  describe "check/1" do
    test "returns allow with remaining count for simple key" do
      key = TestHelper.unique_key("check_simple")

      result = RateLtd.check(key)
      assert {:allow, remaining} = result
      assert is_integer(remaining) and remaining >= 0
    end

    test "returns allow with remaining count for grouped bucket" do
      result = RateLtd.check({"user123", "api"})
      assert {:allow, remaining} = result
      assert is_integer(remaining) and remaining >= 0
    end

    test "decreases remaining count with each check" do
      key = TestHelper.unique_key("check_decrease")

      {:allow, remaining1} = RateLtd.check(key)
      {:allow, remaining2} = RateLtd.check(key)

      assert remaining2 == remaining1 - 1
    end

    test "returns deny when limit exceeded" do
      key = TestHelper.unique_key("check_limit")

      # Configure very low limit
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 1, window_ms: 60_000, max_queue_size: 100}
      })

      # First check should allow
      assert {:allow, 0} = RateLtd.check(key)

      # Second check should deny
      assert {:deny, retry_after} = RateLtd.check(key)
      assert is_integer(retry_after) and retry_after > 0
    end
  end

  describe "reset/1" do
    test "resets rate limit for simple key" do
      key = TestHelper.unique_key("reset_simple")

      # Use up the limit
      RateLtd.check(key)
      RateLtd.check(key)

      # Reset
      assert :ok = RateLtd.reset(key)

      # Should be able to make requests again
      assert {:allow, _} = RateLtd.check(key)
    end

    test "resets rate limit for grouped bucket" do
      # Use some of the limit
      RateLtd.check({"user123", "api"})
      RateLtd.check({"user123", "api"})

      # Reset
      assert :ok = RateLtd.reset({"user123", "api"})

      # Should be back to full limit
      {:allow, remaining} = RateLtd.check({"user123", "api"})
      # 1000 - 1 (for the check we just made)
      assert remaining == 999
    end
  end

  describe "get_bucket_stats/1" do
    test "returns stats for simple bucket" do
      key = TestHelper.unique_key("stats_simple")

      # Make a request to create the bucket
      RateLtd.check(key)

      stats = RateLtd.get_bucket_stats(key)

      assert %{
               bucket_key: bucket_key,
               original_key: ^key,
               bucket_type: :simple_bucket,
               limit: 100,
               window_ms: 60_000
             } = stats

      assert bucket_key == "simple:#{key}"
    end

    test "returns stats for grouped bucket" do
      stats = RateLtd.get_bucket_stats({"user123", "api"})

      assert %{
               bucket_key: "bucket:api:user123",
               original_key: {"user123", "api"},
               bucket_type: :grouped_bucket,
               limit: 1000,
               window_ms: 60_000
             } = stats
    end

    test "includes usage information" do
      key = TestHelper.unique_key("stats_usage")

      # Make some requests
      RateLtd.check(key)
      RateLtd.check(key)

      stats = RateLtd.get_bucket_stats(key)

      # Should show usage
      assert %{used: used, remaining: remaining} = stats
      assert used == 2
      # 100 - 2
      assert remaining == 98
    end
  end

  describe "list_active_buckets/0" do
    test "returns list of active bucket keys" do
      key1 = TestHelper.unique_key("list_test1")
      key2 = TestHelper.unique_key("list_test2")

      # Create some buckets by making requests
      RateLtd.check(key1)
      RateLtd.check({"user2", "api"})
      RateLtd.check(key2)

      buckets = RateLtd.list_active_buckets()
      assert is_list(buckets)

      # Should include our test buckets
      assert "simple:#{key1}" in buckets
      assert "simple:#{key2}" in buckets
      assert "bucket:api:user2" in buckets
    end

    test "returns empty list when no buckets exist" do
      TestHelper.clear_redis()

      buckets = RateLtd.list_active_buckets()
      assert [] = buckets
    end
  end

  describe "get_group_summary/1" do
    test "returns summary for existing group with pending message counts" do
      # Create some buckets in the group
      RateLtd.check({"user1", "api"})
      RateLtd.check({"user2", "api"})
      RateLtd.check({"user3", "api"})

      summary = RateLtd.get_group_summary("api")

      assert %{
               group: "api",
               bucket_count: bucket_count,
               buckets: buckets,
               total_usage: total_usage,
               total_pending: total_pending,
               local_pending: local_pending,
               avg_utilization: avg_utilization,
               peak_utilization: peak_utilization
             } = summary

      # Validate data types and values
      assert bucket_count >= 3
      assert is_list(buckets)
      assert length(buckets) == bucket_count
      assert is_integer(total_usage) and total_usage >= 0
      assert is_integer(total_pending) and total_pending >= 0
      assert is_integer(local_pending) and local_pending >= 0
      assert is_float(avg_utilization) and avg_utilization >= 0.0
      assert is_float(peak_utilization) and peak_utilization >= 0.0

      # Check that buckets include pending_messages field
      Enum.each(buckets, fn bucket ->
        assert Map.has_key?(bucket, :pending_messages)
        assert is_integer(bucket.pending_messages)
      end)
    end

    test "returns empty summary for non-existing group" do
      summary = RateLtd.get_group_summary("nonexistent")

      assert %{
               group: "nonexistent",
               bucket_count: 0,
               buckets: [],
               total_usage: 0,
               total_pending: 0,
               local_pending: 0,
               avg_utilization: +0.0,
               peak_utilization: +0.0
             } = summary
    end

    test "correctly counts local pending messages" do
      # Add some items to local queue for the group
      config = %{max_queue_size: 10}

      request1 = %{
        "id" => "test-1",
        "rate_limit_key" => "bucket:api:user1",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      request2 = %{
        "id" => "test-2",
        "rate_limit_key" => "bucket:api:user2",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      RateLtd.LocalQueue.enqueue(request1, config)
      RateLtd.LocalQueue.enqueue(request2, config)

      summary = RateLtd.get_group_summary("api")
      assert summary.local_pending == 2
    end
  end

  describe "key normalization" do
    test "normalizes simple string keys correctly" do
      key = TestHelper.unique_key("normalize")

      stats1 = RateLtd.get_bucket_stats(key)
      stats2 = RateLtd.get_bucket_stats(key)

      # Both should have the same bucket_key
      assert stats1.bucket_key == stats2.bucket_key
      assert stats1.bucket_key == "simple:#{key}"
    end

    test "normalizes tuple keys correctly" do
      stats = RateLtd.get_bucket_stats({"api_key_123", "payment"})
      assert stats.bucket_key == "bucket:payment:api_key_123"
    end
  end

  describe "configuration resolution" do
    test "uses custom config when available" do
      stats = RateLtd.get_bucket_stats("test_key")
      # From configs
      assert stats.limit == 10
    end

    test "uses group config for grouped buckets" do
      stats = RateLtd.get_bucket_stats({"regular_user", "api"})
      # From group_configs
      assert stats.limit == 1000
    end

    test "uses api_key specific config when available" do
      stats = RateLtd.get_bucket_stats({"premium_user", "api"})
      # From api_key_configs
      assert stats.limit == 5000
    end

    test "falls back to defaults when no custom config" do
      key = TestHelper.unique_key("default_config")
      stats = RateLtd.get_bucket_stats(key)
      # From defaults
      assert stats.limit == 100
    end
  end

  describe "sliding window behavior" do
    test "requests expire after window period" do
      key = TestHelper.unique_key("sliding_window")

      # Configure short window for testing
      Application.put_env(:rate_ltd, :configs, %{
        # 1 second window
        key => %{limit: 2, window_ms: 1000, max_queue_size: 100}
      })

      # Use up the limit
      assert {:allow, 1} = RateLtd.check(key)
      assert {:allow, 0} = RateLtd.check(key)
      assert {:deny, _} = RateLtd.check(key)

      # Wait for window to slide
      Process.sleep(1100)

      # Should be able to make requests again
      assert {:allow, _} = RateLtd.check(key)
    end
  end

  describe "concurrent access with local queue" do
    test "handles multiple processes accessing same key with queueing" do
      key = TestHelper.unique_key("concurrent")

      # Configure small limit to force queueing
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 3, window_ms: 3000, max_queue_size: 10}
      })

      # Spawn multiple processes
      tasks =
        Enum.map(1..8, fn i ->
          Task.async(fn ->
            RateLtd.request(
              key,
              fn ->
                # Simulate some work
                Process.sleep(100)
                "result_#{i}"
              end,
              timeout_ms: 10_000
            )
          end)
        end)

      # Wait a bit for queuing to happen
      Process.sleep(200)

      # Check that some requests are queued
      pending = RateLtd.LocalQueue.count_local_pending()
      assert pending > 0

      results = Task.await_many(tasks, 15_000)

      # All should complete successfully
      assert length(results) == 8

      Enum.each(results, fn result ->
        assert match?({:ok, _}, result)
      end)

      # Queue should be empty after processing
      assert RateLtd.LocalQueue.count_local_pending() == 0
    end
  end

  describe "node isolation" do
    test "local queue is isolated to current node" do
      # This test verifies that the local queue only affects the current node
      # In a real distributed test, you would verify across multiple nodes

      config = %{max_queue_size: 5}

      request = %{
        "id" => "node-test",
        "rate_limit_key" => "test:node:isolation",
        "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
        "queued_at" => System.system_time(:millisecond),
        "expires_at" => System.system_time(:millisecond) + 30_000
      }

      # Add to local queue
      {:ok, _} = RateLtd.LocalQueue.enqueue(request, config)

      # Verify it's in our local queue
      assert RateLtd.LocalQueue.count_local_pending() == 1

      # Verify it's tracked in Redis counters
      pending_key = "rate_ltd:pending:test:node:isolation"
      {:ok, count_str} = RateLtd.Redis.command(["GET", pending_key])
      assert String.to_integer(count_str) == 1

      # Clean up
      {:ok, _} = RateLtd.LocalQueue.dequeue()
      assert RateLtd.LocalQueue.count_local_pending() == 0
    end
  end
end
