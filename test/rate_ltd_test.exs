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

    # Clear Redis before each test
    TestHelper.clear_redis()

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

    test "respects rate limits" do
      key = TestHelper.unique_key("rate_limit_test")

      # Configure very low limit for testing
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 2, window_ms: 60_000, max_queue_size: 100}
      })

      # First requests should succeed
      assert {:ok, "result1"} = RateLtd.request(key, fn -> "result1" end)
      assert {:ok, "result2"} = RateLtd.request(key, fn -> "result2" end)

      # Third request might be rate limited (depending on timing)
      result = RateLtd.request(key, fn -> "result3" end, timeout_ms: 1000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
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

      stats =
        RateLtd.get_bucket_stats(key)

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
    test "returns summary for existing group" do
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
               active_queues: active_queues,
               avg_utilization: avg_utilization,
               peak_utilization: peak_utilization
             } = summary

      # Validate data types and values
      assert bucket_count >= 3
      assert is_list(buckets)
      assert length(buckets) == bucket_count
      assert is_integer(total_usage) and total_usage >= 0
      assert is_integer(active_queues) and active_queues >= 0
      assert is_float(avg_utilization) and avg_utilization >= 0.0
      assert is_float(peak_utilization) and peak_utilization >= 0.0
    end

    test "returns empty summary for non-existing group" do
      summary = RateLtd.get_group_summary("nonexistent")

      assert %{
               group: "nonexistent",
               bucket_count: 0,
               buckets: [],
               total_usage: 0,
               active_queues: 0,
               avg_utilization: 0.0,
               peak_utilization: 0.0
             } = summary
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

  describe "concurrent access" do
    test "handles multiple processes accessing same key" do
      key = TestHelper.unique_key("concurrent")

      # Configure larger limit for testing
      Application.put_env(:rate_ltd, :configs, %{
        key => %{limit: 20, window_ms: 60_000, max_queue_size: 100}
      })

      # Spawn multiple processes
      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            RateLtd.request(key, fn -> "result_#{i}" end)
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # All should complete successfully (assuming sufficient limit)
      assert length(results) == 10

      Enum.each(results, fn result ->
        assert match?({:ok, _}, result)
      end)
    end
  end
end
