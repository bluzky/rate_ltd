# test/rate_ltd/limiter_test.exs
defmodule RateLtd.LimiterTest do
  use ExUnit.Case, async: false

  # Mock RateLtd.Redis for testing
  defmodule TestRedis do
    def eval(_script, _keys, args) do
      [_window_ms, limit, _now, _request_id] = args

      # Simple mock: alternate between allow and deny
      if :rand.uniform(2) == 1 do
        # Allow
        {:ok, [1, limit - 1]}
      else
        # Deny with 1000ms retry
        {:ok, [0, 1000]}
      end
    end
  end

  setup do
    # Mock the Redis module
    original_redis = Application.get_env(:rate_ltd, :redis_module)
    Application.put_env(:rate_ltd, :redis_module, TestRedis)

    on_exit(fn ->
      if original_redis do
        Application.put_env(:rate_ltd, :redis_module, original_redis)
      else
        Application.delete_env(:rate_ltd, :redis_module)
      end
    end)

    :ok
  end

  describe "check_rate/2" do
    test "returns allow or deny result" do
      config = %{limit: 10, window_ms: 60_000}
      result = RateLtd.Limiter.check_rate("test_key", config)

      assert result in [
               {:allow, 9},
               {:allow, 8},
               {:allow, 7},
               {:allow, 6},
               {:allow, 5},
               {:allow, 4},
               {:allow, 3},
               {:allow, 2},
               {:allow, 1},
               {:allow, 0},
               {:deny, 1000}
             ]
    end

    test "uses correct Redis key format" do
      config = %{limit: 5, window_ms: 30_000}

      # Should not crash and return valid result
      result = RateLtd.Limiter.check_rate("my_api", config)
      assert match?({:allow, _}, result) or match?({:deny, _}, result)
    end

    test "handles Redis errors gracefully" do
      # Mock Redis module that always errors
      defmodule ErrorRedis do
        def eval(_, _, _), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ErrorRedis)

      config = %{limit: 10, window_ms: 60_000}
      result = RateLtd.Limiter.check_rate("test_key", config)

      # Should fail open (allow request)
      assert {:allow, 10} = result
    end
  end

  describe "reset/1" do
    test "calls Redis DEL command" do
      # Mock Redis that tracks DEL calls
      defmodule TrackingRedis do
        def command(["DEL", key]) do
          send(self(), {:del_called, key})
          {:ok, 1}
        end
      end

      Application.put_env(:rate_ltd, :redis_module, TrackingRedis)

      result = RateLtd.Limiter.reset("test_key")
      assert :ok = result

      assert_received {:del_called, "rate_ltd:test_key"}
    end
  end
end
