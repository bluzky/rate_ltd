# lib/rate_ltd.ex
defmodule RateLtd do
  @moduledoc """
  Enhanced rate limiter with tuple-based API supporting grouped buckets.

  Supports both simple string keys and {api_key, group} tuples for
  fine-grained rate limiting control.

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
  """

  @type rate_limit_key :: String.t() | {String.t(), String.t()}
  @type result :: {:ok, term()} | {:error, term()}

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

  @spec check(rate_limit_key()) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(key) do
    normalized_key = normalize_key(key)
    config = RateLtd.ConfigManager.get_config(normalized_key)
    RateLtd.Limiter.check_rate(normalized_key, config)
  end

  @spec reset(rate_limit_key()) :: :ok
  def reset(key) do
    normalized_key = normalize_key(key)
    RateLtd.Limiter.reset(normalized_key)
  end

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

  @spec list_active_buckets() :: [String.t()]
  def list_active_buckets do
    RateLtd.BucketManager.list_active_buckets()
  end

  @spec get_group_summary(String.t()) :: map()
  def get_group_summary(group) do
    RateLtd.BucketManager.get_group_summary(group)
  end

  # Private functions

  defp normalize_key({api_key, group}) when is_binary(api_key) and is_binary(group) do
    "bucket:#{group}:#{api_key}"
  end

  defp normalize_key(key) when is_binary(key) do
    "simple:#{key}"
  end

  defp get_bucket_type({_api_key, _group}), do: :grouped_bucket
  defp get_bucket_type(_key), do: :simple_bucket

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

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
end
