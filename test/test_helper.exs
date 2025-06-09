# test/test_helper.exs
ExUnit.start()

# Test configuration for Redis
Application.put_env(:rate_ltd, :redis,
  host: System.get_env("REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
  # Use DB 15 for tests
  database: String.to_integer(System.get_env("REDIS_TEST_DB", "15")),
  pool_size: 2
)

# Test helper functions
defmodule RateLtd.TestHelper do
  @moduledoc """
  Helper functions for RateLtd tests using real Redis with local queue support.
  """

  @doc """
  Clears all RateLtd test data from Redis.
  """
  def clear_redis do
    case RateLtd.Redis.command(["FLUSHDB"]) do
      {:ok, _} -> :ok
      # Ignore errors during cleanup
      {:error, _} -> :ok
    end
  end

  @doc """
  Clears the local ETS queue table.
  """
  def clear_local_queue do
    try do
      :ets.delete_all_objects(:rate_ltd_local_queue)
    rescue
      ArgumentError ->
        # Table doesn't exist yet, create it
        RateLtd.LocalQueue.init()
    end
  end

  @doc """
  Ensures local queue ETS table is initialized.
  """
  def setup_local_queue do
    try do
      # Check if table exists
      :ets.info(:rate_ltd_local_queue)
      :ok
    rescue
      ArgumentError ->
        # Table doesn't exist, create it
        RateLtd.LocalQueue.init()
        :ok
    end
  end

  @doc """
  Waits for Redis to be available before running tests.
  """
  def wait_for_redis(retries \\ 30) do
    case RateLtd.Redis.command(["PING"]) do
      {:ok, "PONG"} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(100)
        wait_for_redis(retries - 1)

      _ ->
        raise "Redis not available for testing. Please ensure Redis is running on #{redis_host()}:#{redis_port()}"
    end
  end

  @doc """
  Creates test bucket data in Redis for testing.
  """
  def setup_test_buckets do
    now = System.system_time(:millisecond)

    # Add some test data to buckets
    RateLtd.Redis.eval(
      """
      local bucket_key = KEYS[1]
      local now = tonumber(ARGV[1])

      -- Add some test requests to the bucket
      for i = 1, 5 do
        redis.call('ZADD', bucket_key, now - (i * 1000), 'req_' .. i)
      end

      redis.call('EXPIRE', bucket_key, 3600)
      """,
      ["rate_ltd:bucket:api:user1"],
      [now]
    )

    RateLtd.Redis.eval(
      """
      local bucket_key = KEYS[1]
      local now = tonumber(ARGV[1])

      -- Add some test requests to the bucket
      for i = 1, 3 do
        redis.call('ZADD', bucket_key, now - (i * 2000), 'req_' .. i)
      end

      redis.call('EXPIRE', bucket_key, 3600)
      """,
      ["rate_ltd:bucket:api:user2"],
      [now]
    )

    RateLtd.Redis.eval(
      """
      local bucket_key = KEYS[1]
      local now = tonumber(ARGV[1])

      -- Add some test requests to the bucket
      for i = 1, 2 do
        redis.call('ZADD', bucket_key, now - (i * 3000), 'req_' .. i)
      end

      redis.call('EXPIRE', bucket_key, 3600)
      """,
      ["rate_ltd:bucket:payment:merchant1"],
      [now]
    )

    # Add simple bucket
    RateLtd.Redis.eval(
      """
      local bucket_key = KEYS[1]
      local now = tonumber(ARGV[1])

      redis.call('ZADD', bucket_key, now - 1000, 'simple_req_1')
      redis.call('EXPIRE', bucket_key, 3600)
      """,
      ["rate_ltd:simple:legacy_key"],
      [now]
    )
  end

  @doc """
  Sets up test pending counters in Redis for testing metrics.
  """
  def setup_test_pending_counters do
    # Set some pending message counters
    RateLtd.Redis.command(["SET", "rate_ltd:pending:bucket:api:user1", "3"])
    RateLtd.Redis.command(["EXPIRE", "rate_ltd:pending:bucket:api:user1", 3600])

    RateLtd.Redis.command(["SET", "rate_ltd:pending:bucket:api:user2", "1"])
    RateLtd.Redis.command(["EXPIRE", "rate_ltd:pending:bucket:api:user2", 3600])

    RateLtd.Redis.command(["SET", "rate_ltd:pending:simple:test_key", "2"])
    RateLtd.Redis.command(["EXPIRE", "rate_ltd:pending:simple:test_key", 3600])
  end

  @doc """
  Creates test local queue entries for testing.
  """
  def setup_test_local_queue do
    setup_local_queue()

    config = build_test_config()
    now = System.system_time(:millisecond)

    request1 = %{
      "id" => "local_queue_req_1",
      "rate_limit_key" => "bucket:api:user1",
      "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
      "queued_at" => now - 5000,
      "expires_at" => now + 25000
    }

    request2 = %{
      "id" => "local_queue_req_2",
      "rate_limit_key" => "bucket:api:user2",
      "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
      "queued_at" => now - 3000,
      "expires_at" => now + 27000
    }

    RateLtd.LocalQueue.enqueue(request1, config)
    RateLtd.LocalQueue.enqueue(request2, config)
  end

  @doc """
  Builds a test config map with default values.
  """
  def build_test_config(opts \\ []) do
    %{
      limit: Keyword.get(opts, :limit, 100),
      window_ms: Keyword.get(opts, :window_ms, 60_000),
      max_queue_size: Keyword.get(opts, :max_queue_size, 1000)
    }
  end

  @doc """
  Generates a unique test key to avoid conflicts between tests.
  """
  def unique_key(prefix \\ "test") do
    "#{prefix}_#{System.unique_integer([:positive])}_#{:rand.uniform(10000)}"
  end

  @doc """
  Waits for a condition to be true with timeout.
  """
  def wait_until(fun, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_until(fun, deadline)
      else
        {:error, :timeout}
      end
    end
  end

  @doc """
  Checks if Redis is available for testing.
  """
  def redis_available? do
    case RateLtd.Redis.command(["PING"]) do
      {:ok, "PONG"} -> true
      _ -> false
    end
  end

  @doc """
  Gets the pending message count from Redis for a specific rate limit key.
  """
  def get_redis_pending_count(rate_limit_key) do
    pending_key = "rate_ltd:pending:#{rate_limit_key}"

    case RateLtd.Redis.command(["GET", pending_key]) do
      {:ok, nil} -> 0
      {:ok, count_str} -> String.to_integer(count_str)
      _ -> 0
    end
  end

  @doc """
  Gets the current count of items in the local queue.
  """
  def get_local_queue_count do
    try do
      RateLtd.LocalQueue.count_local_pending()
    rescue
      ArgumentError ->
        # Table doesn't exist
        0
    end
  end

  @doc """
  Counts Redis keys matching a pattern.
  """
  def count_redis_keys(pattern) do
    case RateLtd.Redis.command(["KEYS", pattern]) do
      {:ok, keys} -> length(keys)
      _ -> 0
    end
  end

  @doc """
  Simulates expired request by creating one with past expiration.
  """
  def create_expired_request(rate_limit_key \\ "simple:expired_test") do
    now = System.system_time(:millisecond)

    %{
      "id" => "expired_#{:rand.uniform(10000)}",
      "rate_limit_key" => rate_limit_key,
      "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
      "queued_at" => now - 35000,
      # Already expired
      "expires_at" => now - 5000
    }
  end

  @doc """
  Waits for the queue processor to process pending items.
  """
  def wait_for_queue_processing(timeout \\ 3000) do
    initial_count = get_local_queue_count()

    wait_until(
      fn ->
        get_local_queue_count() < initial_count
      end,
      timeout
    )
  end

  @doc """
  Verifies that Redis pending counters match expected values.
  """
  def verify_pending_counters(expected_counts) do
    Enum.all?(expected_counts, fn {rate_limit_key, expected_count} ->
      actual_count = get_redis_pending_count(rate_limit_key)
      actual_count == expected_count
    end)
  end

  defp redis_host do
    Application.get_env(:rate_ltd, :redis)[:host]
  end

  defp redis_port do
    Application.get_env(:rate_ltd, :redis)[:port]
  end
end

# Global test setup
ExUnit.configure(exclude: [skip: true])

# Start Redis connection for tests
case RateLtd.Redis.start_link(Application.get_env(:rate_ltd, :redis)) do
  {:ok, _} ->
    RateLtd.TestHelper.wait_for_redis()
    IO.puts("✓ Connected to Redis for testing")

  {:error, {:already_started, _}} ->
    RateLtd.TestHelper.wait_for_redis()
    IO.puts("✓ Redis already started for testing")

  {:error, reason} ->
    IO.puts("✗ Failed to connect to Redis: #{inspect(reason)}")
    IO.puts("Please ensure Redis is running and accessible")
    System.halt(1)
end

# Clear any existing test data and initialize clean state
RateLtd.TestHelper.clear_redis()
RateLtd.TestHelper.clear_local_queue()

IO.puts("✓ Test environment initialized with local queue support")
