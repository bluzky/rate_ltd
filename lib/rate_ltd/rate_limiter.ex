defmodule RateLtd.Limiter do
  @moduledoc """
  Rate limiting logic using Redis sliding window algorithm.
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
    redis.call('EXPIRE', key, math.ceil(window_ms / 1000))

    local remaining = limit - current_count - 1
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

  def check_rate(key, config) do
    now = System.system_time(:millisecond)
    request_id = generate_id()
    redis_key = "rate_ltd:#{key}"

    case RateLtd.Redis.eval(@sliding_window_script, [redis_key], [
           config.window_ms,
           config.limit,
           now,
           request_id
         ]) do
      {:ok, [1, remaining]} -> {:allow, remaining}
      {:ok, [0, retry_after]} -> {:deny, retry_after}
      # Fail open
      {:error, _reason} -> {:allow, config.limit}
    end
  end

  def reset(key) do
    redis_key = "rate_ltd:#{key}"
    RateLtd.Redis.command(["DEL", redis_key])
    :ok
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
end
