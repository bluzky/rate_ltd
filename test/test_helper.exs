ExUnit.start()

# Don't start the application automatically in test_helper
# Let individual tests start it if needed

# Start Redis for testing
case System.cmd("redis-cli", ["ping"], stderr_to_stdout: true) do
  {"PONG\n", 0} ->
    IO.puts("Redis is running")
  _ ->
    IO.puts("Warning: Redis is not running. Some tests may fail.")
end

# Helper functions for tests
defmodule RateLtd.TestHelpers do
  @moduledoc """
  Helper functions for RateLtd tests.
  """

  def clear_redis do
    case RateLtd.RedisManager.command(["FLUSHDB"]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok  # Ignore Redis errors in tests
    end
  end

  def wait_for_processing(ms \\ 200) do
    Process.sleep(ms)
  end

  def create_test_rate_config(key, limit \\ 5, window_ms \\ 1000) do
    RateLtd.RateLimitConfig.new(key, limit, window_ms)
  end

  def create_test_queue_config(name, opts \\ []) do
    default_opts = [max_size: 10, request_timeout_ms: 5000]
    RateLtd.QueueConfig.new(name, Keyword.merge(default_opts, opts))
  end

  def make_test_function(return_value \\ :test_result) do
    fn -> return_value end
  end

  def make_slow_function(delay_ms \\ 100, return_value \\ :slow_result) do
    fn ->
      Process.sleep(delay_ms)
      return_value
    end
  end

  def make_error_function(error \\ :test_error) do
    fn -> raise error end
  end
end
