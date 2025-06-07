# lib/rate_ltd/limiter.ex
defmodule RateLtd.Limiter do
  @moduledoc """
  Enhanced rate limiting logic using Redis sliding window algorithm.

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

  @batch_check_script """
  local keys = {}
  local window_ms = tonumber(ARGV[1])
  local now = tonumber(ARGV[3])

  -- Extract keys from KEYS array
  for i = 1, #KEYS do
    keys[i] = KEYS[i]
  end

  local results = {}

  for i = 1, #keys do
    local key = keys[i]
    local limit = tonumber(ARGV[i + 3]) -- limits start from ARGV[4]

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get current count
    local current_count = redis.call('ZCARD', key)

    if current_count < limit then
      local remaining = limit - current_count
      results[i] = {1, remaining}
    else
      -- Get the oldest entry to calculate retry_after
      local oldest_entries = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
      local retry_after = 0

      if #oldest_entries > 0 then
        local oldest_time = tonumber(oldest_entries[2])
        retry_after = math.max(0, (oldest_time + window_ms) - now)
      end

      results[i] = {0, retry_after}
    end
  end

  return results
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
      {:error, reason} ->
        log_redis_error("check_rate", key, reason)
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
      {:error, reason} ->
        log_redis_error("check_rate_without_increment", key, reason)
        {:allow, config.limit}
    end
  end

  @spec batch_check_rates([{String.t(), map()}]) :: [check_result()]
  def batch_check_rates(key_config_pairs) when is_list(key_config_pairs) do
    case key_config_pairs do
      [] ->
        []

      pairs ->
        now = System.system_time(:millisecond)
        redis_keys = Enum.map(pairs, fn {key, _config} -> "rate_ltd:#{key}" end)

        # Assume all have the same window_ms for batch operation
        {_first_key, first_config} = hd(pairs)
        limits = Enum.map(pairs, fn {_key, config} -> config.limit end)

        argv = [first_config.window_ms, "batch", now] ++ limits

        case redis_module().eval(@batch_check_script, redis_keys, argv) do
          {:ok, results} ->
            Enum.map(results, fn
              [1, remaining] -> {:allow, remaining}
              [0, retry_after] -> {:deny, retry_after}
            end)

          {:error, reason} ->
            log_redis_error("batch_check_rates", "batch", reason)
            # Fail open - return allow for all
            Enum.map(pairs, fn {_key, config} -> {:allow, config.limit} end)
        end
    end
  end

  @spec reset(String.t()) :: :ok
  def reset(key) do
    redis_key = "rate_ltd:#{key}"

    case redis_module().command(["DEL", redis_key]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_redis_error("reset", key, reason)
        :ok
    end
  end

  @spec reset_batch([String.t()]) :: :ok
  def reset_batch(keys) when is_list(keys) do
    redis_keys = Enum.map(keys, &"rate_ltd:#{&1}")

    case redis_keys do
      [] ->
        :ok

      keys_to_delete ->
        case redis_module().command(["DEL"] ++ keys_to_delete) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            log_redis_error("reset_batch", "batch", reason)
            :ok
        end
    end
  end

  @spec get_current_usage(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_current_usage(key, config) do
    now = System.system_time(:millisecond)
    redis_key = "rate_ltd:#{key}"

    usage_script = """
    local key = KEYS[1]
    local window_ms = tonumber(ARGV[1])
    local now = tonumber(ARGV[2])

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get current count
    return redis.call('ZCARD', key)
    """

    case redis_module().eval(usage_script, [redis_key], [config.window_ms, now]) do
      {:ok, usage} -> {:ok, usage}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_usage_history(String.t(), map(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_usage_history(key, config, intervals \\ 10) do
    now = System.system_time(:millisecond)
    redis_key = "rate_ltd:#{key}"
    interval_size = div(config.window_ms, intervals)

    history_script = """
    local key = KEYS[1]
    local window_ms = tonumber(ARGV[1])
    local now = tonumber(ARGV[2])
    local intervals = tonumber(ARGV[3])
    local interval_size = tonumber(ARGV[4])

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get all timestamps in the window
    local timestamps = redis.call('ZRANGE', key, 0, -1, 'WITHSCORES')

    local buckets = {}
    for i = 1, intervals do
      buckets[i] = 0
    end

    -- Count requests in each interval
    for i = 2, #timestamps, 2 do
      local timestamp = tonumber(timestamps[i])
      local age = now - timestamp
      local bucket_index = math.min(intervals, math.ceil(age / interval_size))
      buckets[bucket_index] = buckets[bucket_index] + 1
    end

    return buckets
    """

    case redis_module().eval(history_script, [redis_key], [
           config.window_ms,
           now,
           intervals,
           interval_size
         ]) do
      {:ok, buckets} ->
        history =
          buckets
          |> Enum.with_index(1)
          |> Enum.map(fn {count, index} ->
            interval_start = now - index * interval_size
            interval_end = now - (index - 1) * interval_size

            %{
              interval: index,
              start_time: interval_start,
              end_time: interval_end,
              request_count: count,
              interval_size_ms: interval_size
            }
          end)
          |> Enum.reverse()

        {:ok, history}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec increment_usage(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def increment_usage(key, config) do
    now = System.system_time(:millisecond)
    request_id = generate_id()
    redis_key = "rate_ltd:#{key}"

    increment_script = """
    local key = KEYS[1]
    local window_ms = tonumber(ARGV[1])
    local now = tonumber(ARGV[2])
    local request_id = ARGV[3]

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Add the new request
    redis.call('ZADD', key, now, request_id)
    redis.call('EXPIRE', key, math.ceil(window_ms / 1000) + 1)

    -- Return new count
    return redis.call('ZCARD', key)
    """

    case redis_module().eval(increment_script, [redis_key], [
           config.window_ms,
           now,
           request_id
         ]) do
      {:ok, new_count} -> {:ok, new_count}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_window_info(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_window_info(key, config) do
    now = System.system_time(:millisecond)
    redis_key = "rate_ltd:#{key}"

    window_script = """
    local key = KEYS[1]
    local window_ms = tonumber(ARGV[1])
    local now = tonumber(ARGV[2])

    -- Clean up expired entries
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get current count and oldest/newest timestamps
    local count = redis.call('ZCARD', key)

    if count == 0 then
      return {count, 0, 0}
    end

    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local newest = redis.call('ZRANGE', key, -1, -1, 'WITHSCORES')

    local oldest_time = 0
    local newest_time = 0

    if #oldest > 0 then
      oldest_time = tonumber(oldest[2])
    end

    if #newest > 0 then
      newest_time = tonumber(newest[2])
    end

    return {count, oldest_time, newest_time}
    """

    case redis_module().eval(window_script, [redis_key], [config.window_ms, now]) do
      {:ok, [count, oldest_time, newest_time]} ->
        window_start = now - config.window_ms

        info = %{
          current_count: count,
          limit: config.limit,
          remaining: max(0, config.limit - count),
          window_start: window_start,
          window_end: now,
          window_size_ms: config.window_ms,
          oldest_request: if(oldest_time > 0, do: oldest_time, else: nil),
          newest_request: if(newest_time > 0, do: newest_time, else: nil),
          utilization_percent: if(config.limit > 0, do: count / config.limit * 100, else: 0),
          next_reset: if(oldest_time > 0, do: oldest_time + config.window_ms, else: now)
        }

        {:ok, info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)

  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end

  defp log_redis_error(operation, key, reason) do
    require Logger

    Logger.warning(
      "RateLtd.Limiter Redis error in #{operation} for key #{key}: #{inspect(reason)}"
    )
  end
end
