# lib/rate_ltd/bucket_manager.ex
defmodule RateLtd.BucketManager do
  @moduledoc """
  Manages and provides insights into active rate limit buckets.

  Provides functionality to:
  - List all active buckets
  - Get group summaries and statistics
  """

  @type group_summary :: %{
          group: String.t(),
          bucket_count: non_neg_integer(),
          buckets: [map()],
          total_usage: non_neg_integer(),
          active_queues: non_neg_integer(),
          avg_utilization: float(),
          peak_utilization: float()
        }

  @spec list_active_buckets() :: [String.t()]
  def list_active_buckets do
    bucket_keys = get_keys_by_pattern("rate_ltd:bucket:*")
    simple_keys = get_keys_by_pattern("rate_ltd:simple:*")

    (bucket_keys ++ simple_keys)
    |> Enum.map(&extract_bucket_name/1)
    |> Enum.reject(&is_nil/1)
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

  # Private functions

  defp get_keys_by_pattern(pattern) do
    case redis_module().command(["KEYS", pattern]) do
      {:ok, keys} -> keys
      {:error, _} -> []
    end
  end

  defp extract_bucket_name("rate_ltd:" <> bucket_name), do: bucket_name
  defp extract_bucket_name(_), do: nil

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

  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
