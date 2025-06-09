# lib/rate_ltd/limiter.ex
defmodule RateLtd.Limiter do
  @moduledoc """
  Rate limiting logic using Redis sliding window algorithm.

  Supports both grouped buckets and simple keys with precise
  sliding window rate limiting using Redis sorted sets.
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

  @spec reset(String.t()) :: :ok
  def reset(key) do
    redis_key = "rate_ltd:#{key}"

    case redis_module().command(["DEL", redis_key]) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  # Private functions

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)

  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
