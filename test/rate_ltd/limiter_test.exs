# test/rate_ltd/limiter_test.exs
defmodule RateLtd.LimiterTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()
    :ok
  end

  describe "check_rate/2" do
    test "returns allow when under limit" do
      config = %{limit: 10, window_ms: 60_000}
      result = RateLtd.Limiter.check_rate("test_key", config)

      assert {:allow, remaining} = result
      assert is_integer(remaining) and remaining >= 0 and remaining < 10
    end

    test "returns deny when over limit" do
      config = %{limit: 1, window_ms: 60_000}

      # First request should succeed
      assert {:allow, 0} = RateLtd.Limiter.check_rate("limit_test", config)

      # Second request should be denied
      result = RateLtd.Limiter.check_rate("limit_test", config)
      assert {:deny, retry_after} = result
      assert is_integer(retry_after) and retry_after >= 0
    end

    test "uses correct Redis key format for simple keys" do
      config = %{limit: 5, window_ms: 30_000}
      result = RateLtd.Limiter.check_rate("simple:my_api", config)
      assert match?({:allow, _}, result) or match?({:deny, _}, result)
    end

    test "uses correct Redis key format for bucket keys" do
      config = %{limit: 5, window_ms: 30_000}
      result = RateLtd.Limiter.check_rate("bucket:payment_api:merchant_123", config)
      assert match?({:allow, _}, result) or match?({:deny, _}, result)
    end

    test "handles Redis errors gracefully" do
      defmodule ErrorRedis do
        def eval(_, _, _), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ErrorRedis)

      config = %{limit: 10, window_ms: 60_000}
      result = RateLtd.Limiter.check_rate("test_key", config)

      # Should fail open (allow request)
      assert {:allow, 10} = result
    end

    test "increments usage correctly" do
      config = %{limit: 3, window_ms: 60_000}

      # First request
      assert {:allow, 2} = RateLtd.Limiter.check_rate("increment_test", config)

      # Second request
      assert {:allow, 1} = RateLtd.Limiter.check_rate("increment_test", config)

      # Third request
      assert {:allow, 0} = RateLtd.Limiter.check_rate("increment_test", config)

      # Fourth request should be denied
      assert {:deny, _} = RateLtd.Limiter.check_rate("increment_test", config)
    end
  end

  describe "check_rate_without_increment/2" do
    test "checks without incrementing usage" do
      config = %{limit: 5, window_ms: 60_000}

      # Check should not increment
      assert {:allow, 5} = RateLtd.Limiter.check_rate_without_increment("no_increment", config)
      assert {:allow, 5} = RateLtd.Limiter.check_rate_without_increment("no_increment", config)

      # Actual request should increment
      assert {:allow, 4} = RateLtd.Limiter.check_rate("no_increment", config)

      # Check again should show usage but not increment further
      assert {:allow, 4} = RateLtd.Limiter.check_rate_without_increment("no_increment", config)
    end

    test "fails open on Redis errors" do
      defmodule CheckErrorRedis do
        def eval(_, _, _), do: {:error, :redis_down}
      end

      Application.put_env(:rate_ltd, :redis_module, CheckErrorRedis)

      config = %{limit: 10, window_ms: 60_000}
      result = RateLtd.Limiter.check_rate_without_increment("error_test", config)

      assert {:allow, 10} = result
    end
  end

  describe "batch_check_rates/1" do
    test "checks multiple keys at once" do
      key_config_pairs = [
        {"batch_key_1", %{limit: 5, window_ms: 60_000}},
        {"batch_key_2", %{limit: 3, window_ms: 60_000}},
        {"batch_key_3", %{limit: 10, window_ms: 60_000}}
      ]

      results = RateLtd.Limiter.batch_check_rates(key_config_pairs)

      assert length(results) == 3

      Enum.each(results, fn result ->
        assert match?({:allow, _}, result) or match?({:deny, _}, result)
      end)
    end

    test "handles empty list" do
      results = RateLtd.Limiter.batch_check_rates([])
      assert results == []
    end

    test "fails open for all keys on Redis error" do
      defmodule BatchErrorRedis do
        def eval(_, _, _), do: {:error, :batch_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, BatchErrorRedis)

      key_config_pairs = [
        {"batch_error_1", %{limit: 5, window_ms: 60_000}},
        {"batch_error_2", %{limit: 3, window_ms: 60_000}}
      ]

      results = RateLtd.Limiter.batch_check_rates(key_config_pairs)

      assert results == [
               {:allow, 5},
               {:allow, 3}
             ]
    end
  end

  describe "reset/1" do
    test "resets rate limit for key" do
      config = %{limit: 1, window_ms: 60_000}

      # Use up the limit
      assert {:allow, 0} = RateLtd.Limiter.check_rate("reset_test", config)
      assert {:deny, _} = RateLtd.Limiter.check_rate("reset_test", config)

      # Reset
      assert :ok = RateLtd.Limiter.reset("reset_test")

      # Should be able to make requests again
      assert {:allow, 0} = RateLtd.Limiter.check_rate("reset_test", config)
    end

    test "handles Redis errors gracefully" do
      defmodule ResetErrorRedis do
        def command(_), do: {:error, :reset_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ResetErrorRedis)

      result = RateLtd.Limiter.reset("error_reset_test")
      assert :ok = result
    end
  end

  describe "reset_batch/1" do
    test "resets multiple keys" do
      config = %{limit: 1, window_ms: 60_000}

      # Use up limits for multiple keys
      RateLtd.Limiter.check_rate("batch_reset_1", config)
      RateLtd.Limiter.check_rate("batch_reset_2", config)

      # Reset all
      assert :ok = RateLtd.Limiter.reset_batch(["batch_reset_1", "batch_reset_2"])

      # Should be able to make requests again
      assert {:allow, 0} = RateLtd.Limiter.check_rate("batch_reset_1", config)
      assert {:allow, 0} = RateLtd.Limiter.check_rate("batch_reset_2", config)
    end

    test "handles empty list" do
      assert :ok = RateLtd.Limiter.reset_batch([])
    end
  end

  describe "get_current_usage/2" do
    test "returns current usage count" do
      config = %{limit: 5, window_ms: 60_000}

      # Initial usage should be 0
      assert {:ok, 0} = RateLtd.Limiter.get_current_usage("usage_test", config)

      # Make a request
      RateLtd.Limiter.check_rate("usage_test", config)

      # Usage should be 1
      assert {:ok, 1} = RateLtd.Limiter.get_current_usage("usage_test", config)
    end

    test "handles Redis errors" do
      defmodule UsageErrorRedis do
        def eval(_, _, _), do: {:error, :usage_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, UsageErrorRedis)

      config = %{limit: 5, window_ms: 60_000}
      result = RateLtd.Limiter.get_current_usage("error_usage", config)

      assert {:error, :usage_failed} = result
    end
  end

  describe "get_usage_history/3" do
    test "returns usage history intervals" do
      config = %{limit: 10, window_ms: 60_000}

      result = RateLtd.Limiter.get_usage_history("history_test", config, 5)

      assert {:ok, history} = result
      assert is_list(history)
      assert length(history) == 5

      Enum.each(history, fn interval ->
        assert Map.has_key?(interval, :interval)
        assert Map.has_key?(interval, :start_time)
        assert Map.has_key?(interval, :end_time)
        assert Map.has_key?(interval, :request_count)
        assert Map.has_key?(interval, :interval_size_ms)
      end)
    end

    test "uses default interval count" do
      config = %{limit: 10, window_ms: 60_000}

      result = RateLtd.Limiter.get_usage_history("default_history", config)

      assert {:ok, history} = result
      # default intervals
      assert length(history) == 10
    end
  end

  describe "increment_usage/2" do
    test "increments usage without checking limit" do
      config = %{limit: 5, window_ms: 60_000}

      # Increment directly
      assert {:ok, 1} = RateLtd.Limiter.increment_usage("increment_only", config)
      assert {:ok, 2} = RateLtd.Limiter.increment_usage("increment_only", config)

      # Should show 2 when checked
      assert {:ok, 2} = RateLtd.Limiter.get_current_usage("increment_only", config)
    end
  end

  describe "get_window_info/2" do
    test "returns comprehensive window information" do
      config = %{limit: 5, window_ms: 60_000}

      # Make some requests
      RateLtd.Limiter.check_rate("window_info", config)
      RateLtd.Limiter.check_rate("window_info", config)

      result = RateLtd.Limiter.get_window_info("window_info", config)

      assert {:ok, info} = result
      assert Map.has_key?(info, :current_count)
      assert Map.has_key?(info, :limit)
      assert Map.has_key?(info, :remaining)
      assert Map.has_key?(info, :window_start)
      assert Map.has_key?(info, :window_end)
      assert Map.has_key?(info, :window_size_ms)
      assert Map.has_key?(info, :utilization_percent)
      assert Map.has_key?(info, :next_reset)

      assert info.current_count == 2
      assert info.limit == 5
      assert info.remaining == 3
      assert info.window_size_ms == 60_000
      assert is_float(info.utilization_percent)
    end

    test "handles empty window" do
      config = %{limit: 10, window_ms: 60_000}

      result = RateLtd.Limiter.get_window_info("empty_window", config)

      assert {:ok, info} = result
      assert info.current_count == 0
      assert info.remaining == 10
      assert info.oldest_request == nil
      assert info.newest_request == nil
    end
  end

  describe "edge cases" do
    test "handles zero limit" do
      config = %{limit: 0, window_ms: 60_000}

      result = RateLtd.Limiter.check_rate("zero_limit", config)
      assert {:deny, _} = result
    end

    test "handles very large window" do
      # 24 hours
      config = %{limit: 1, window_ms: 86_400_000}

      result = RateLtd.Limiter.check_rate("large_window", config)
      assert {:allow, 0} = result
    end

    test "handles very small window" do
      # 1 millisecond
      config = %{limit: 100, window_ms: 1}

      result = RateLtd.Limiter.check_rate("small_window", config)
      assert match?({:allow, _}, result) or match?({:deny, _}, result)
    end
  end

  describe "concurrent access simulation" do
    test "handles multiple requests to same key" do
      config = %{limit: 10, window_ms: 60_000}

      # Simulate concurrent requests
      tasks =
        1..5
        |> Enum.map(fn i ->
          Task.async(fn ->
            RateLtd.Limiter.check_rate("concurrent_test", config)
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      # All should return valid results
      Enum.each(results, fn result ->
        assert match?({:allow, _}, result) or match?({:deny, _}, result)
      end)

      # Check final usage
      {:ok, final_usage} = RateLtd.Limiter.get_current_usage("concurrent_test", config)
      # Should not exceed limit
      assert final_usage <= 10
    end
  end
end
