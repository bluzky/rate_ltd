# lib/rate_ltd/limiter.ex
defmodule RateLtd.Limiter do
  @moduledoc """
  Rate limiting logic using Redis sliding window algorithm.

  Supports both grouped buckets and simple keys with precise
  sliding window rate limiting using Redis sorted sets.

  ## Algorithm

  Uses a sliding window approach where:
  1. Each request is stored as a scored entry in a Redis sorted set
  2. The score is the timestamp of the request
  3. Expired entries are automatically cleaned up before each check
  4. Rate limiting decision is made based on current window count vs limit

  ## Redis Key Format

  Rate limit data is stored in Redis with keys formatted as:
  - `rate_ltd:bucket:group:api_key` for grouped buckets
  - `rate_ltd:simple:key` for simple buckets

  ## Error Handling

  The limiter uses a "fail open" strategy - if Redis is unavailable,
  requests are allowed through to prevent service disruption.
  """

  @sliding_window_script """
  local key = KEYS[1]
  local window_ms = tonumber(ARGV[1])
  local limit = tonumber(ARGV[2])
  local now = tonumber(ARGV[3])
  local request_id = ARGV[4]

  -- Clean up expired entries
  local window_start = now - window_ms
  redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

  -- Get current count
  local current_count = redis.call('ZCARD', key)

  if current_count < limit then
    -- Add the new request
    redis.call('ZADD', key, now, request_id)
    redis.call('EXPIRE', key, math.ceil(window_ms / 1000) + 1)

    local remaining = limit - current_count - 1
    return {1, remaining, now}
  else
    -- Get the oldest entry to calculate retry_after
    local oldest_entries = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = 0

    if #oldest_entries > 0 then
      local oldest_time = tonumber(oldest_entries[2])
      retry_after = math.max(0, (oldest_time + window_ms) - now)
    end

    return {0, retry_after, now}
  end
  """

  @type check_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @doc """
  Checks if a request should be allowed based on rate limits and increments the counter.

  This is the primary rate limiting function that both checks the current
  rate and increments the counter atomically using a Redis Lua script.

  ## Parameters

    * `key` - The rate limit key (e.g., "bucket:payment:api_123" or "simple:legacy_key")
    * `config` - Configuration map containing `:limit` and `:window_ms`

  ## Returns

    * `{:allow, remaining}` - Request allowed, with remaining requests in window
    * `{:deny, retry_after_ms}` - Request denied, with milliseconds until retry

  ## Examples

      # Allow a request
      iex> config = %{limit: 100, window_ms: 60_000}
      iex> RateLtd.Limiter.check_rate("bucket:api:user_123", config)
      {:allow, 99}

      # Deny when limit exceeded
      iex> RateLtd.Limiter.check_rate("bucket:api:user_456", config)
      {:deny, 45000}

  ## Algorithm Details

  1. Cleans up expired entries from the sliding window
  2. Checks if current count is below limit
  3. If allowed: adds new entry and returns remaining capacity
  4. If denied: calculates retry time based on oldest entry
  5. All operations are atomic via Redis Lua script

  ## Error Handling

  Returns `{:allow, limit}` if Redis is unavailable (fail-open behavior).
  """
  @spec check_rate(String.t(), map()) :: check_result()
  def check_rate(key, config) do
    now = System.system_time(:millisecond)
    request_id = generate_id()
    redis_key = "rate_ltd:#{key}"

    case redis_module().eval(@sliding_window_script, [redis_key], [
           config.window_ms,
           config.limit,
           now,
           request_id
         ]) do
      {:ok, [1, remaining, _timestamp]} ->
        {:allow, remaining}

      {:ok, [0, retry_after, _timestamp]} ->
        {:deny, retry_after}

      # Fail open on Redis errors
      {:error, _reason} ->
        {:allow, config.limit}
    end
  end

  @doc """
  Checks rate limit status without incrementing the counter.

  Useful for inspecting current rate limit status without consuming
  a request slot. Often used for monitoring or queue processing decisions.

  ## Parameters

    * `key` - The rate limit key
    * `config` - Configuration map containing `:limit` and `:window_ms`

  ## Returns

    * `{:allow, remaining}` - Would be allowed, with remaining requests
    * `{:deny, retry_after_ms}` - Would be denied, with retry time

  ## Examples

      # Check without consuming
      iex> config = %{limit: 100, window_ms: 60_000}
      iex> RateLtd.Limiter.check_rate_without_increment("bucket:api:user_123", config)
      {:allow, 50}

      # Check again - same result since no increment
      iex> RateLtd.Limiter.check_rate_without_increment("bucket:api:user_123", config)
      {:allow, 50}

  ## Use Cases

  - Queue processing: check before dequeuing requests
  - Monitoring: inspect current utilization
  - Conditional logic: make decisions based on capacity
  """
  @spec check_rate_without_increment(String.t(), map()) :: check_result()
  def check_rate_without_increment(key, config) do
    now = System.system_time(:millisecond)
    redis_key = "rate_ltd:#{key}"

    check_script = """
    local key = KEYS[1]
    local window_ms = tonumber(ARGV[1])
    local limit = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get current count
    local current_count = redis.call('ZCARD', key)

    if current_count < limit then
      local remaining = limit - current_count
      return {1, remaining}
    else
      -- Get the oldest entry to calculate retry_after
      local oldest_entries = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
      local retry_after = 0

      if #oldest_entries > 0 then
        local oldest_time = tonumber(oldest_entries[2])
        retry_after = math.max(0, (oldest_time + window_ms) - now)
      end

      return {0, retry_after}
    end
    """

    case redis_module().eval(check_script, [redis_key], [
           config.window_ms,
           config.limit,
           now
         ]) do
      {:ok, [1, remaining]} ->
        {:allow, remaining}

      {:ok, [0, retry_after]} ->
        {:deny, retry_after}

      # Fail open on Redis errors
      {:error, _reason} ->
        {:allow, config.limit}
    end
  end

  @doc """
  Resets the rate limit for a given key.

  Completely clears the sliding window for the specified key,
  effectively resetting the rate limit counter to zero.

  ## Parameters

    * `key` - The rate limit key to reset

  ## Returns

  Always returns `:ok`, even if Redis operations fail.

  ## Examples

      # Reset rate limit for a key
      iex> RateLtd.Limiter.reset("bucket:api:user_123")
      :ok

      # Key is now clear for new requests
      iex> config = %{limit: 100, window_ms: 60_000}
      iex> RateLtd.Limiter.check_rate("bucket:api:user_123", config)
      {:allow, 99}

  ## Use Cases

  - Administrative resets
  - Testing and development
  - Emergency override situations
  - User account reactivation
  """
  @spec reset(String.t()) :: :ok
  def reset(key) do
    redis_key = "rate_ltd:#{key}"

    case redis_module().command(["DEL", redis_key]) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  # Private functions

  @doc false
  # Generates a unique request ID for Redis sorted set entries
  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)

  @doc false
  # Returns the configured Redis module, with fallback for testing
  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
