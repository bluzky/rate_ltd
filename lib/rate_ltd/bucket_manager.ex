# lib/rate_ltd/bucket_manager.ex
defmodule RateLtd.BucketManager do
  @moduledoc """
  Manages and provides insights into active rate limit buckets.

  Provides functionality to:
  - List all active buckets
  - Get group summaries and statistics
  - Monitor bucket utilization
  - Clean up expired buckets
  """

  @type bucket_info :: %{
          bucket_key: String.t(),
          current_usage: non_neg_integer(),
          limit: non_neg_integer(),
          window_ms: non_neg_integer(),
          utilization: float()
        }

  @type group_summary :: %{
          group: String.t(),
          bucket_count: non_neg_integer(),
          buckets: [bucket_info()],
          total_usage: non_neg_integer(),
          active_queues: non_neg_integer(),
          avg_utilization: float(),
          peak_utilization: float()
        }

  @spec list_active_buckets() :: [String.t()]
  def list_active_buckets do
    case redis_module().command(["KEYS", "rate_ltd:bucket:*", "rate_ltd:simple:*"]) do
      {:ok, keys} ->
        (keys || [])
        |> Enum.map(&extract_bucket_name/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @spec get_group_summary(String.t()) :: group_summary()
  def get_group_summary(group) do
    pattern = "rate_ltd:bucket:#{group}:*"

    case redis_module().command(["KEYS", pattern]) do
      {:ok, keys} ->
        buckets =
          keys
          |> Enum.map(&extract_bucket_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&get_bucket_info/1)
          |> Enum.reject(&match?({:error, _}, &1))
          |> Enum.map(fn {:ok, info} -> info end)

        %{
          group: group,
          bucket_count: length(buckets),
          buckets: buckets,
          total_usage: calculate_total_usage(buckets),
          active_queues: count_active_queues(group),
          avg_utilization: calculate_avg_utilization(buckets),
          peak_utilization: calculate_peak_utilization(buckets)
        }

      {:error, _} ->
        %{
          group: group,
          bucket_count: 0,
          buckets: [],
          total_usage: 0,
          active_queues: 0,
          avg_utilization: 0.0,
          peak_utilization: 0.0
        }
    end
  end

  @spec get_all_groups() :: [String.t()]
  def get_all_groups do
    case redis_module().command(["KEYS", "rate_ltd:bucket:*"]) do
      {:ok, keys} ->
        keys
        |> Enum.map(&extract_group_from_key/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  @spec get_system_overview() :: map()
  def get_system_overview do
    groups = get_all_groups()
    simple_buckets = get_simple_bucket_count()

    group_summaries =
      groups
      |> Enum.map(&get_group_summary/1)
      |> Enum.reject(&(&1.bucket_count == 0))

    total_buckets =
      Enum.reduce(group_summaries, simple_buckets, fn summary, acc ->
        acc + summary.bucket_count
      end)

    total_usage =
      Enum.reduce(group_summaries, 0, fn summary, acc ->
        acc + summary.total_usage
      end)

    %{
      total_buckets: total_buckets,
      grouped_buckets: total_buckets - simple_buckets,
      simple_buckets: simple_buckets,
      total_usage: total_usage,
      groups: group_summaries,
      active_groups: length(group_summaries)
    }
  end

  @spec cleanup_expired_buckets() :: {:ok, non_neg_integer()}
  def cleanup_expired_buckets do
    # This would typically be called by a background job
    # Redis automatically expires keys, but we can help by cleaning up empty sorted sets

    script = """
    local keys = redis.call('KEYS', 'rate_ltd:*')
    local cleaned = 0

    for i = 1, #keys do
      local key = keys[i]
      if redis.call('TYPE', key).ok == 'zset' then
        local count = redis.call('ZCARD', key)
        if count == 0 then
          redis.call('DEL', key)
          cleaned = cleaned + 1
        end
      end
    end

    return cleaned
    """

    case redis_module().eval(script, [], []) do
      {:ok, cleaned_count} -> {:ok, cleaned_count}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_bucket_details(String.t()) :: {:ok, map()} | {:error, term()}
  def get_bucket_details(bucket_key) do
    redis_key = "rate_ltd:#{bucket_key}"
    config = RateLtd.ConfigManager.get_config(bucket_key)

    # Get current usage and recent request timestamps
    script = """
    local key = ARGV[1]
    local window_ms = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])

    -- Clean expired entries first
    local window_start = now - window_ms
    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

    -- Get current count and all timestamps
    local count = redis.call('ZCARD', key)
    local timestamps = redis.call('ZRANGE', key, 0, -1, 'WITHSCORES')

    return {count, timestamps}
    """

    now = System.system_time(:millisecond)

    case redis_module().eval(script, [], [redis_key, config.window_ms, now]) do
      {:ok, [count, timestamps]} ->
        request_times = parse_timestamps(timestamps)

        {:ok,
         %{
           bucket_key: bucket_key,
           config: config,
           current_usage: count,
           remaining: max(0, config.limit - count),
           utilization: if(config.limit > 0, do: count / config.limit * 100, else: 0),
           window_start: now - config.window_ms,
           window_end: now,
           recent_requests: request_times,
           next_reset: calculate_next_reset(request_times, config.window_ms, now)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp extract_bucket_name("rate_ltd:" <> bucket_name), do: bucket_name
  defp extract_bucket_name(_), do: nil

  defp extract_group_from_key("rate_ltd:bucket:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [group, _api_key] -> group
      _ -> nil
    end
  end

  defp extract_group_from_key(_), do: nil

  defp get_bucket_info(bucket_key) do
    redis_key = "rate_ltd:#{bucket_key}"

    case redis_module().command(["ZCARD", redis_key]) do
      {:ok, count} ->
        config = RateLtd.ConfigManager.get_config(bucket_key)

        {:ok,
         %{
           bucket_key: bucket_key,
           current_usage: count,
           limit: config.limit,
           window_ms: config.window_ms,
           utilization: if(config.limit > 0, do: count / config.limit * 100, else: 0)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_simple_bucket_count do
    case redis_module().command(["KEYS", "rate_ltd:simple:*"]) do
      {:ok, keys} -> length(keys)
      {:error, _} -> 0
    end
  end

  defp calculate_total_usage(buckets) do
    Enum.reduce(buckets, 0, fn bucket, acc ->
      acc + bucket.current_usage
    end)
  end

  defp calculate_avg_utilization([]), do: 0.0

  defp calculate_avg_utilization(buckets) do
    total_utilization =
      Enum.reduce(buckets, 0.0, fn bucket, acc ->
        acc + bucket.utilization
      end)

    total_utilization / length(buckets)
  end

  defp calculate_peak_utilization([]), do: 0.0

  defp calculate_peak_utilization(buckets) do
    buckets
    |> Enum.map(& &1.utilization)
    |> Enum.max()
  end

  defp count_active_queues(group) do
    pattern = "rate_ltd:queue:bucket:#{group}:*"

    case redis_module().command(["KEYS", pattern]) do
      {:ok, keys} -> length(keys)
      {:error, _} -> 0
    end
  end

  defp parse_timestamps(timestamps) do
    timestamps
    |> Enum.chunk_every(2)
    |> Enum.map(fn [_request_id, timestamp] ->
      String.to_integer(timestamp)
    end)
    |> Enum.sort(:desc)
  end

  defp calculate_next_reset([], _window_ms, now), do: now

  defp calculate_next_reset(request_times, window_ms, _now) do
    oldest_request = Enum.min(request_times)
    oldest_request + window_ms
  end

  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
