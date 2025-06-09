# lib/rate_ltd.ex
defmodule RateLtd do
  @moduledoc """
  Enhanced rate limiter with tuple-based API supporting grouped buckets.

  Supports both simple string keys and {group, api_key} tuples for
  fine-grained rate limiting control with local queuing and parallel processing.

  ## Features

  - **Grouped Buckets**: Use {group, api_key} tuples for service-specific rate limiting
  - **Simple Keys**: Traditional string-based rate limiting for backward compatibility
  - **Local Queuing**: ETS-based local queue with Redis counters for metrics
  - **Parallel Processing**: Process queued requests in parallel by rate limit key
  - **Sliding Window**: Precise rate limiting using Redis sorted sets
  - **Configuration Hierarchy**: API key > group > global defaults
  - **Fail-Safe**: Graceful degradation on Redis errors

  ## Configuration

  Configure in your `config.exs`:

      config :rate_ltd,
        # Global defaults
        defaults: [limit: 100, window_ms: 60_000, max_queue_size: 1000],

        # Group-level configurations
        group_configs: %{
          "payment_api" => %{limit: 1000, window_ms: 60_000, max_queue_size: 500},
          "search_api" => %{limit: 5000, window_ms: 60_000, max_queue_size: 2000}
        },

        # API key specific configurations (highest priority)
        api_key_configs: %{
          "payment_api:premium_merchant_123" => %{limit: 5000, window_ms: 60_000},
          "search_api:enterprise_client_456" => %{limit: 50000, window_ms: 60_000}
        },

        # Simple key configurations (backward compatibility)
        configs: %{
          "legacy_api_key" => %{limit: 200, window_ms: 60_000}
        },

        # Redis configuration
        redis: [
          host: "localhost",
          port: 6379,
          database: 0,
          pool_size: 5
        ],

        # Queue processing interval
        queue_check_interval: 1000

  ## Examples

      # Simple string key
      RateLtd.request("api_user_123", fn ->
        API.call()
      end)

      # Grouped bucket - separate limits per service
      RateLtd.request({"merchant_123", "payment_api"}, fn ->
        PaymentProcessor.charge(params)
      end)

      RateLtd.request({"merchant_123", "search_api"}, fn ->
        SearchService.query(params)
      end)

      # Check rate limit without consuming quota
      case RateLtd.check({"merchant_123", "payment_api"}) do
        {:allow, remaining} ->
          IO.puts("Allowed, \#{remaining} requests remaining")
        {:deny, retry_after} ->
          IO.puts("Rate limited, retry after \#{retry_after}ms")
      end

      # Get detailed bucket statistics
      stats = RateLtd.get_bucket_stats({"merchant_123", "payment_api"})
      # => %{
      #   bucket_key: "bucket:payment_api:merchant_123",
      #   original_key: {"merchant_123", "payment_api"},
      #   used: 150,
      #   remaining: 350,
      #   limit: 500,
      #   window_ms: 60000,
      #   bucket_type: :grouped_bucket
      # }

      # Monitoring and observability
      active_buckets = RateLtd.list_active_buckets()
      payment_summary = RateLtd.get_group_summary("payment_api")

  ## Architecture

  The library uses a distributed architecture with:

  - **Local ETS Queue**: Each node maintains its own request queue
  - **Redis Backend**: Shared rate limiting state and pending counters
  - **Parallel Processing**: Queued requests processed by rate limit key
  - **Configuration Manager**: Hierarchical configuration resolution
  - **Bucket Manager**: Monitoring and statistics collection

  ## Rate Limiting Algorithm

  Uses a sliding window algorithm implemented with Redis sorted sets:
  1. Requests are timestamped and stored in a sorted set
  2. Expired entries are automatically cleaned up
  3. Current usage is calculated by counting valid entries
  4. Precise retry timing based on oldest entry expiration

  ## Error Handling

  The library implements graceful error handling:
  - **Redis Failures**: Fails open (allows requests) when Redis is unavailable
  - **Queue Full**: Returns `{:error, :queue_full}` when local queue is full
  - **Timeouts**: Configurable timeout for queued requests
  - **Dead Processes**: Automatically cleans up requests from dead processes
  """

  @type rate_limit_key :: String.t() | {String.t(), String.t()}
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Execute a function with rate limiting.

  ## Parameters
  - `key`: Rate limit key (string or {group, api_key} tuple)
  - `function`: Function to execute when rate limit allows
  - `opts`: Options (timeout_ms, max_retries)

  ## Returns
  - `{:ok, result}`: Function executed successfully
  - `{:error, :timeout}`: Request timed out in queue
  - `{:error, :queue_full}`: Local queue is full
  - `{:error, {:function_error, error}}`: Function raised an error
  """
  @spec request(rate_limit_key(), function()) :: result()
  @spec request(rate_limit_key(), function(), keyword()) :: result()
  def request(key, function, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_retries = Keyword.get(opts, :max_retries, 3)

    normalized_key = normalize_key(key)

    case attempt_with_retries(normalized_key, function, max_retries) do
      {:ok, result} -> {:ok, result}
      :rate_limited -> queue_and_wait(normalized_key, function, timeout_ms)
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Check rate limit status without consuming quota.

  ## Parameters
  - `key`: Rate limit key (string or {group, api_key} tuple)

  ## Returns
  - `{:allow, remaining}`: Request would be allowed with remaining quota
  - `{:deny, retry_after}`: Request would be denied, retry after milliseconds
  """
  @spec check(rate_limit_key()) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(key) do
    normalized_key = normalize_key(key)
    config = RateLtd.ConfigManager.get_config(normalized_key)
    RateLtd.Limiter.check_rate_without_increment(normalized_key, config)
  end

  @doc """
  Reset rate limit bucket for a specific key.

  Clears all rate limiting history for the given key.

  ## Parameters
  - `key`: Rate limit key (string or {group, api_key} tuple)
  """
  @spec reset(rate_limit_key()) :: :ok
  def reset(key) do
    normalized_key = normalize_key(key)
    RateLtd.Limiter.reset(normalized_key)
  end

  @doc """
  Get detailed statistics for a rate limit bucket.

  ## Parameters
  - `key`: Rate limit key (string or {group, api_key} tuple)

  ## Returns
  Map containing bucket statistics including usage, remaining quota, limits, and timing.
  """
  @spec get_bucket_stats(rate_limit_key()) :: map()
  def get_bucket_stats(key) do
    normalized_key = normalize_key(key)
    config = RateLtd.ConfigManager.get_config(normalized_key)

    case RateLtd.Limiter.check_rate_without_increment(normalized_key, config) do
      {:allow, remaining} ->
        %{
          bucket_key: normalized_key,
          original_key: key,
          used: config.limit - remaining,
          remaining: remaining,
          limit: config.limit,
          window_ms: config.window_ms,
          bucket_type: get_bucket_type(key)
        }

      {:deny, retry_after} ->
        %{
          bucket_key: normalized_key,
          original_key: key,
          used: config.limit,
          remaining: 0,
          limit: config.limit,
          window_ms: config.window_ms,
          retry_after_ms: retry_after,
          bucket_type: get_bucket_type(key)
        }
    end
  end

  @doc """
  List all currently active rate limit buckets.

  Returns a list of bucket keys that have active rate limiting state.
  """
  @spec list_active_buckets() :: [String.t()]
  def list_active_buckets do
    RateLtd.BucketManager.list_active_buckets()
  end

  @doc """
  Get summary statistics for a specific group.

  ## Parameters
  - `group`: Group name (e.g., "payment_api", "search_api")

  ## Returns
  Map containing group-level statistics including bucket count, usage, and utilization.
  """
  @spec get_group_summary(String.t()) :: map()
  def get_group_summary(group) do
    RateLtd.BucketManager.get_group_summary(group)
  end

  # Private functions

  # Convert {group, api_key} tuple to normalized bucket key
  defp normalize_key({group, api_key}) when is_binary(api_key) and is_binary(group) do
    "bucket:#{group}:#{api_key}"
  end

  # Convert simple string key to normalized simple key
  defp normalize_key(key) when is_binary(key) do
    "simple:#{key}"
  end

  # Determine bucket type from original key format
  defp get_bucket_type({_group, _api_key}), do: :grouped_bucket
  defp get_bucket_type(_key), do: :simple_bucket

  # Attempt to execute function with immediate rate limiting
  defp attempt_with_retries(normalized_key, function, retries_left) when retries_left > 0 do
    config = RateLtd.ConfigManager.get_config(normalized_key)

    case RateLtd.Limiter.check_rate(normalized_key, config) do
      {:allow, _remaining} ->
        try do
          {:ok, function.()}
        rescue
          error -> {:error, {:function_error, error}}
        end

      {:deny, retry_after} when retry_after < 1000 ->
        Process.sleep(retry_after)
        attempt_with_retries(normalized_key, function, retries_left - 1)

      {:deny, _retry_after} ->
        :rate_limited
    end
  end

  defp attempt_with_retries(_normalized_key, _function, 0), do: :rate_limited

  # Queue request and wait for execution signal
  defp queue_and_wait(normalized_key, function, timeout_ms) do
    config = RateLtd.ConfigManager.get_config(normalized_key)
    request_id = generate_id()

    request = %{
      "id" => request_id,
      "rate_limit_key" => normalized_key,
      "caller_pid" => :erlang.term_to_binary(self()) |> Base.encode64(),
      "queued_at" => System.system_time(:millisecond),
      "expires_at" => System.system_time(:millisecond) + timeout_ms
    }

    case RateLtd.LocalQueue.enqueue(request, config) do
      {:ok, _position} ->
        receive do
          {:rate_ltd_execute, ^request_id} ->
            try do
              {:ok, function.()}
            rescue
              error -> {:error, {:function_error, error}}
            end
        after
          timeout_ms -> {:error, :timeout}
        end

      {:error, :queue_full} ->
        {:error, :queue_full}
    end
  end

  # Generate unique request ID
  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
end
