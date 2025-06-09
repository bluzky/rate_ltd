# lib/rate_ltd/bucket_manager.ex
defmodule RateLtd.BucketManager do
  @moduledoc """
  Manages and provides insights into active rate limit buckets.

  Provides functionality to:
  - List all active buckets across Redis
  - Get detailed group summaries with statistics
  - Monitor utilization and pending request metrics
  - Combine Redis rate limit data with local queue information

  ## Metrics Provided

  - **Current Usage**: Active requests in sliding window
  - **Utilization**: Percentage of rate limit capacity used
  - **Pending Requests**: Queued requests waiting for processing
  - **Local vs Global**: Node-local vs cluster-wide pending counts

  ## Use Cases

  - Monitoring dashboards
  - Capacity planning
  - Performance debugging
  - Operational visibility
  """

  @type group_summary :: %{
          group: String.t(),
          bucket_count: non_neg_integer(),
          buckets: [map()],
          total_usage: non_neg_integer(),
          total_pending: non_neg_integer(),
          local_pending: non_neg_integer(),
          avg_utilization: float(),
          peak_utilization: float()
        }

  @doc """
  Lists all active rate limit buckets.

  Scans Redis for all rate limiting keys and extracts the bucket names.
  Includes both grouped buckets and simple buckets.

  ## Returns

  List of bucket key strings (without Redis key prefixes).

  ## Examples

      iex> RateLtd.BucketManager.list_active_buckets()
      [
        "bucket:payment_api:merchant_123",
        "bucket:search_api:client_456",
        "simple:legacy_key"
      ]

  ## Performance Note

  Uses Redis KEYS command, which can be slow on large datasets.
  Consider using SCAN in production for better performance.
  """
  @spec list_active_buckets() :: [String.t()]
  def list_active_buckets do
    bucket_keys = get_keys_by_pattern("rate_ltd:bucket:*")
    simple_keys = get_keys_by_pattern("rate_ltd:simple:*")

    (bucket_keys ++ simple_keys)
    |> Enum.map(&extract_bucket_name/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets comprehensive summary statistics for a rate limit group.

  Provides detailed analytics for all buckets within a specific group,
  including utilization metrics, pending request counts, and individual
  bucket statistics.

  ## Parameters

    * `group` - The group name (e.g., "payment_api", "search_api")

  ## Returns

  Group summary map containing:
  - `:group` - Group name
  - `:bucket_count` - Number of active buckets in group
  - `:buckets` - List of individual bucket statistics
  - `:total_usage` - Sum of all bucket usage counts
  - `:total_pending` - Global pending requests for group
  - `:local_pending` - Node-local pending requests for group
  - `:avg_utilization` - Average utilization percentage across buckets
  - `:peak_utilization` - Highest utilization percentage in group

  ## Examples

      iex> RateLtd.BucketManager.get_group_summary("payment_api")
      %{
        group: "payment_api",
        bucket_count: 3,
        buckets: [
          %{
            bucket_key: "bucket:payment_api:merchant_123",
            current_usage: 45,
            pending_messages: 12,
            limit: 1000,
            window_ms: 60_000,
            utilization: 4.5
          }
        ],
        total_usage: 156,
        total_pending: 23,
        local_pending: 8,
        avg_utilization: 15.6,
        peak_utilization: 34.2
      }

  ## Use Cases

  - Group-level monitoring dashboards
  - Capacity planning by API group
  - Performance troubleshooting
  - SLA monitoring and alerting
  """
  @spec get_group_summary(String.t()) :: group_summary()
  def get_group_summary(group) do
    pattern = "rate_ltd:bucket:#{group}:*"

    case redis_module().command(["KEYS", pattern]) do
      {:ok, keys} ->
        buckets =
          keys
          |> Enum.map(&extract_bucket_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&get_bucket_info_with_pending/1)
          |> Enum.reject(&match?({:error, _}, &1))
          |> Enum.map(fn {:ok, info} -> info end)

        %{
          group: group,
          bucket_count: length(buckets),
          buckets: buckets,
          total_usage: calculate_total_usage(buckets),
          total_pending: calculate_total_pending(buckets),
          local_pending: count_local_pending_for_group(group),
          avg_utilization: calculate_avg_utilization(buckets),
          peak_utilization: calculate_peak_utilization(buckets)
        }

      {:error, _} ->
        %{
          group: group,
          bucket_count: 0,
          buckets: [],
          total_usage: 0,
          total_pending: 0,
          local_pending: 0,
          avg_utilization: 0.0,
          peak_utilization: 0.0
        }
    end
  end

  # Private functions

  @doc false
  # Complex function that combines Redis rate limit data with pending request metrics.
  #
  # For each bucket:
  # 1. Gets current usage from Redis sorted set (ZCARD)
  # 2. Gets pending request count from Redis counter
  # 3. Retrieves configuration for limits and window
  # 4. Calculates utilization percentage
  # 5. Handles missing data gracefully
  #
  # This provides a complete view of bucket state including both
  # active rate limit usage and queued requests waiting for processing.
  defp get_bucket_info_with_pending(bucket_key) do
    redis_key = "rate_ltd:#{bucket_key}"
    pending_key = "rate_ltd:pending:#{bucket_key}"

    with {:ok, count} <- redis_module().command(["ZCARD", redis_key]),
         {:ok, pending_str} <- redis_module().command(["GET", pending_key]) do
      config = RateLtd.ConfigManager.get_config(bucket_key)
      pending = if pending_str, do: String.to_integer(pending_str), else: 0

      {:ok,
       %{
         bucket_key: bucket_key,
         current_usage: count,
         pending_messages: pending,
         limit: config.limit,
         window_ms: config.window_ms,
         utilization: if(config.limit > 0, do: count / config.limit * 100, else: 0)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Sums pending messages across all buckets in the group
  defp calculate_total_pending(buckets) do
    Enum.reduce(buckets, 0, fn bucket, acc ->
      acc + Map.get(bucket, :pending_messages, 0)
    end)
  end

  @doc false
  # Counts pending requests in local queue for a specific group.
  # Filters local queue keys to only include those belonging to the group.
  defp count_local_pending_for_group(group) do
    RateLtd.LocalQueue.list_local_queue_keys()
    |> Enum.count(fn key -> String.starts_with?(key, "bucket:#{group}:") end)
  end

  @doc false
  # Retrieves Redis keys matching a pattern using KEYS command
  defp get_keys_by_pattern(pattern) do
    case redis_module().command(["KEYS", pattern]) do
      {:ok, keys} -> keys
      {:error, _} -> []
    end
  end

  @doc false
  # Extracts bucket name from Redis key by removing the "rate_ltd:" prefix
  defp extract_bucket_name("rate_ltd:" <> bucket_name), do: bucket_name
  defp extract_bucket_name(_), do: nil

  @doc false
  # Sums current usage across all buckets
  defp calculate_total_usage(buckets) do
    Enum.reduce(buckets, 0, fn bucket, acc ->
      acc + bucket.current_usage
    end)
  end

  @doc false
  # Calculates average utilization percentage across buckets
  defp calculate_avg_utilization([]), do: 0.0

  defp calculate_avg_utilization(buckets) do
    total_utilization =
      Enum.reduce(buckets, 0.0, fn bucket, acc ->
        acc + bucket.utilization
      end)

    total_utilization / length(buckets)
  end

  @doc false
  # Finds the highest utilization percentage among all buckets
  defp calculate_peak_utilization([]), do: 0.0

  defp calculate_peak_utilization(buckets) do
    buckets
    |> Enum.map(& &1.utilization)
    |> Enum.max()
  end

  @doc false
  # Returns the configured Redis module with fallback for testing
  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
