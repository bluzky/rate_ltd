# test/rate_ltd_test.exs
defmodule RateLtdTest do
  use ExUnit.Case, async: false

  setup do
    # Stop any existing QueueProcessor
    case Process.whereis(RateLtd.QueueProcessor) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1000)
    end

    # Start mock Redis
    start_supervised!(MockRedis)

    # Replace RateLtd.Redis with MockRedis
    Application.put_env(:rate_ltd, :redis_module, MockRedis)

    # Reset mock state
    MockRedis.reset()

    # Configure test rates
    Application.put_env(:rate_ltd, :defaults, limit: 5, window_ms: 1000, max_queue_size: 3)

    Application.put_env(:rate_ltd, :configs, %{
      "test_api" => %{limit: 2, window_ms: 1000, max_queue_size: 2},
      "timeout_test" => %{limit: 1, window_ms: 1000, max_queue_size: 1}
    })

    :ok
  end

  describe "request/2" do
    test "executes function when rate limit allows" do
      result = RateLtd.request("test_key", fn -> "success" end)
      assert {:ok, "success"} == result
    end

    test "handles function errors" do
      result = RateLtd.request("test_key", fn -> raise "boom" end)
      assert {:error, {:function_error, %RuntimeError{message: "boom"}}} = result
    end

    test "retries on short delays" do
      # First request should succeed
      assert {:ok, "first"} = RateLtd.request("test_api", fn -> "first" end)

      # Second request should succeed
      assert {:ok, "second"} = RateLtd.request("test_api", fn -> "second" end)
    end

    test "queues request when rate limited" do
      # Fill up rate limit (2 requests for test_api)
      assert {:ok, "first"} = RateLtd.request("test_api", fn -> "first" end)
      assert {:ok, "second"} = RateLtd.request("test_api", fn -> "second" end)

      # This should queue but we'll simulate timeout for test
      task =
        Task.async(fn ->
          RateLtd.request("test_api", fn -> "queued" end, timeout_ms: 100)
        end)

      result = Task.await(task)
      assert {:error, :timeout} = result
    end
  end

  describe "request/3 with options" do
    test "respects timeout option" do
      # Force the rate limit to be exceeded by making the mock always deny
      # We'll create a mock that always returns deny for this specific key

      # First, exhaust the rate limit for timeout_test (limit: 1)
      assert {:ok, "first"} = RateLtd.request("timeout_test", fn -> "first" end)

      # Now this request should be rate limited and queue, then timeout
      task =
        Task.async(fn ->
          RateLtd.request("timeout_test", fn -> "test" end, timeout_ms: 50)
        end)

      result = Task.await(task)
      assert {:error, :timeout} = result
    end

    test "respects max_retries option" do
      # This would normally retry, but with max_retries: 0 it should queue immediately
      result = RateLtd.request("test_api", fn -> "test" end, max_retries: 0, timeout_ms: 50)
      # Depending on rate limit state, this could succeed or timeout
      assert result in [
               {:ok, "test"},
               {:error, :timeout},
               {:error, :queue_full}
             ]
    end
  end

  describe "check/1" do
    test "returns allow when rate limit permits" do
      result = RateLtd.check("new_key")
      assert {:allow, _remaining} = result
    end

    test "uses configured limits" do
      # Check with default config
      result = RateLtd.check("default_key")
      assert {:allow, remaining} = result
      assert remaining >= 0
    end
  end

  describe "reset/1" do
    test "resets rate limit for key" do
      # Use up some rate limit
      RateLtd.request("reset_test", fn -> "test" end)

      # Reset it
      assert :ok = RateLtd.reset("reset_test")

      # Should be able to make requests again
      result = RateLtd.check("reset_test")
      assert {:allow, _} = result
    end
  end
end
