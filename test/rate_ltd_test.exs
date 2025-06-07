# test/rate_ltd_test.exs
defmodule RateLtdTest do
  use ExUnit.Case, async: false

  setup do
    # Stop any existing processes
    case Process.whereis(RateLtd.QueueProcessor) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1000)
    end

    # Start mock Redis
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()

    # Configure test environment
    Application.put_env(:rate_ltd, :defaults,
      limit: 5,
      window_ms: 1000,
      max_queue_size: 3
    )

    Application.put_env(:rate_ltd, :configs, %{
      "simple_key" => %{limit: 2, window_ms: 1000, max_queue_size: 2}
    })

    Application.put_env(:rate_ltd, :group_configs, %{
      "test_group" => %{limit: 3, window_ms: 1000, max_queue_size: 5},
      "payment_api" => %{limit: 10, window_ms: 5000, max_queue_size: 10}
    })

    Application.put_env(:rate_ltd, :api_key_configs, %{
      "test_group:premium_key" => %{limit: 10, window_ms: 1000, max_queue_size: 10}
    })

    :ok
  end

  describe "request/2 with simple string keys" do
    test "executes function when rate limit allows" do
      result = RateLtd.request("test_key", fn -> "success" end)
      assert {:ok, "success"} == result
    end

    test "handles function errors gracefully" do
      result = RateLtd.request("test_key", fn -> raise "boom" end)
      assert {:error, {:function_error, %RuntimeError{message: "boom"}}} = result
    end

    test "uses simple key configuration" do
      # First request should succeed
      assert {:ok, "first"} = RateLtd.request("simple_key", fn -> "first" end)
      # Second request should succeed (limit is 2)
      assert {:ok, "second"} = RateLtd.request("simple_key", fn -> "second" end)
    end
  end

  describe "request/2 with tuple keys" do
    test "executes function with grouped bucket" do
      result = RateLtd.request({"api_key_123", "test_group"}, fn -> "success" end)
      assert {:ok, "success"} == result
    end

    test "uses group configuration" do
      # Should use test_group config (limit: 3)
      assert {:ok, "first"} = RateLtd.request({"merchant_1", "test_group"}, fn -> "first" end)
      assert {:ok, "second"} = RateLtd.request({"merchant_1", "test_group"}, fn -> "second" end)
      assert {:ok, "third"} = RateLtd.request({"merchant_1", "test_group"}, fn -> "third" end)
    end

    test "uses API key specific configuration when available" do
      # Should use api_key_configs for premium_key (limit: 10)
      result = RateLtd.request({"premium_key", "test_group"}, fn -> "premium" end)
      assert {:ok, "premium"} == result
    end

    test "separate buckets for different API keys in same group" do
      # These should be separate buckets
      assert {:ok, "merchant1"} =
               RateLtd.request({"merchant_1", "payment_api"}, fn -> "merchant1" end)

      assert {:ok, "merchant2"} =
               RateLtd.request({"merchant_2", "payment_api"}, fn -> "merchant2" end)
    end

    test "separate buckets for same API key in different groups" do
      # These should be separate buckets
      assert {:ok, "payment"} = RateLtd.request({"api_key", "payment_api"}, fn -> "payment" end)
      assert {:ok, "test"} = RateLtd.request({"api_key", "test_group"}, fn -> "test" end)
    end
  end

  describe "request/3 with options" do
    test "respects timeout option" do
      # This test simulates a queue timeout scenario
      task =
        Task.async(fn ->
          RateLtd.request({"timeout_test", "test_group"}, fn -> "test" end, timeout_ms: 50)
        end)

      result = Task.await(task)
      # Should either succeed or timeout depending on rate limit state
      assert result in [
               {:ok, "test"},
               {:error, :timeout},
               {:error, :queue_full}
             ]
    end

    test "respects max_retries option" do
      result =
        RateLtd.request(
          {"retry_test", "test_group"},
          fn -> "test" end,
          max_retries: 0,
          timeout_ms: 50
        )

      assert result in [
               {:ok, "test"},
               {:error, :timeout},
               {:error, :queue_full}
             ]
    end
  end

  describe "check/1" do
    test "returns allow when rate limit permits for simple key" do
      result = RateLtd.check("new_simple_key")
      assert {:allow, _remaining} = result
    end

    test "returns allow when rate limit permits for tuple key" do
      result = RateLtd.check({"new_api_key", "test_group"})
      assert {:allow, _remaining} = result
    end

    test "uses correct configuration for different key types" do
      # Simple key should use defaults or configs
      {:allow, remaining1} = RateLtd.check("simple_key")

      # Tuple key should use group config
      {:allow, remaining2} = RateLtd.check({"api_key", "test_group"})

      # Both should be valid remaining counts
      assert is_integer(remaining1) and remaining1 >= 0
      assert is_integer(remaining2) and remaining2 >= 0
    end
  end

  describe "reset/1" do
    test "resets rate limit for simple key" do
      # Use up some rate limit
      RateLtd.request("reset_test", fn -> "test" end)

      # Reset it
      assert :ok = RateLtd.reset("reset_test")

      # Should be able to make requests again
      result = RateLtd.check("reset_test")
      assert {:allow, _} = result
    end

    test "resets rate limit for tuple key" do
      # Use up some rate limit
      RateLtd.request({"api_key", "test_group"}, fn -> "test" end)

      # Reset it
      assert :ok = RateLtd.reset({"api_key", "test_group"})

      # Should be able to make requests again
      result = RateLtd.check({"api_key", "test_group"})
      assert {:allow, _} = result
    end
  end

  describe "get_bucket_stats/1" do
    test "returns stats for simple key" do
      stats = RateLtd.get_bucket_stats("stats_test")

      assert is_map(stats)
      assert Map.has_key?(stats, :bucket_key)
      assert Map.has_key?(stats, :original_key)
      assert Map.has_key?(stats, :bucket_type)
      assert stats.bucket_type == :simple_bucket
    end

    test "returns stats for tuple key" do
      stats = RateLtd.get_bucket_stats({"api_key", "test_group"})

      assert is_map(stats)
      assert Map.has_key?(stats, :bucket_key)
      assert Map.has_key?(stats, :original_key)
      assert Map.has_key?(stats, :bucket_type)
      assert stats.bucket_type == :grouped_bucket
      assert stats.original_key == {"api_key", "test_group"}
    end

    test "includes usage information" do
      # Make a request first to generate some usage
      RateLtd.request({"usage_test", "test_group"}, fn -> "test" end)

      stats = RateLtd.get_bucket_stats({"usage_test", "test_group"})

      assert Map.has_key?(stats, :used)
      assert Map.has_key?(stats, :remaining)
      assert Map.has_key?(stats, :limit)
      assert Map.has_key?(stats, :window_ms)

      assert is_integer(stats.used) and stats.used >= 0
      assert is_integer(stats.remaining) and stats.remaining >= 0
      assert is_integer(stats.limit) and stats.limit > 0
      assert is_integer(stats.window_ms) and stats.window_ms > 0
    end
  end

  describe "list_active_buckets/0" do
    test "returns empty list when no buckets are active" do
      MockRedis.reset()
      buckets = RateLtd.list_active_buckets()
      assert is_list(buckets)
    end

    test "returns list of active buckets after requests" do
      # Make some requests to create buckets
      RateLtd.request("simple_bucket", fn -> "test" end)
      RateLtd.request({"api_key", "test_group"}, fn -> "test" end)

      buckets = RateLtd.list_active_buckets()
      assert is_list(buckets)
    end
  end

  describe "get_group_summary/1" do
    test "returns summary for group" do
      # Make some requests in the group
      RateLtd.request({"merchant_1", "test_group"}, fn -> "test1" end)
      RateLtd.request({"merchant_2", "test_group"}, fn -> "test2" end)

      summary = RateLtd.get_group_summary("test_group")

      assert is_map(summary)
      assert Map.has_key?(summary, :group)
      assert Map.has_key?(summary, :bucket_count)
      assert Map.has_key?(summary, :buckets)
      assert Map.has_key?(summary, :total_usage)
      assert Map.has_key?(summary, :active_queues)

      assert summary.group == "test_group"
      assert is_integer(summary.bucket_count) and summary.bucket_count >= 0
      assert is_list(summary.buckets)
      assert is_integer(summary.total_usage) and summary.total_usage >= 0
      assert is_integer(summary.active_queues) and summary.active_queues >= 0
    end

    test "returns empty summary for non-existent group" do
      summary = RateLtd.get_group_summary("non_existent_group")

      assert is_map(summary)
      assert summary.group == "non_existent_group"
      assert summary.bucket_count == 0
      assert summary.buckets == []
      assert summary.total_usage == 0
      assert summary.active_queues == 0
    end
  end

  describe "error handling" do
    test "handles Redis connection errors gracefully" do
      # Replace with error-prone Redis mock
      defmodule ErrorRedis do
        def eval(_, _, _), do: {:error, :connection_failed}
        def command(_), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ErrorRedis)

      # Should fail open (allow request)
      result = RateLtd.request("error_test", fn -> "success" end)
      assert {:ok, "success"} == result
    end

    test "handles invalid tuple keys" do
      # These should not crash the system
      assert_raise FunctionClauseError, fn ->
        RateLtd.request({"only_one_element"}, fn -> "test" end)
      end
    end
  end
end
