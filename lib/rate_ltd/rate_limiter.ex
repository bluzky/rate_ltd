defmodule RateLtd.RateLimiter do
  @moduledoc """
  Core rate limiting functionality using Redis backend.
  """

  alias RateLtd.{RedisManager, LuaScripts, RateLimitConfig}
  require Logger

  @type check_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  @type status :: %{count: non_neg_integer(), remaining: non_neg_integer(), reset_at: DateTime.t()}

  @spec check_rate(String.t(), RateLimitConfig.t()) :: check_result()
  def check_rate(key, %RateLimitConfig{} = config) do
    now = System.system_time(:millisecond)
    request_id = UUID.uuid4()
    
    redis_key = build_redis_key(key)
    script = get_script_for_algorithm(config.algorithm)
    
    case RedisManager.eval(script, [redis_key], [config.window_ms, config.limit, now, request_id]) do
      {:ok, [1, count, remaining, _reset_at]} ->
        emit_telemetry(:rate_limit_allowed, %{
          key: key,
          count: count,
          remaining: remaining,
          algorithm: config.algorithm
        })
        {:allow, remaining}
        
      {:ok, [0, _count, _remaining, retry_after]} ->
        emit_telemetry(:rate_limit_denied, %{
          key: key,
          retry_after: retry_after,
          algorithm: config.algorithm
        })
        {:deny, retry_after}
        
      {:error, reason} ->
        Logger.error("Rate limit check failed for key #{key}: #{inspect(reason)}")
        emit_telemetry(:rate_limit_error, %{key: key, error: reason})
        # Default to allowing on Redis errors (fail open)
        {:allow, config.limit}
    end
  end

  @spec get_status(String.t(), RateLimitConfig.t()) :: status()
  def get_status(key, %RateLimitConfig{} = config) do
    now = System.system_time(:millisecond)
    redis_key = build_redis_key(key)
    
    case config.algorithm do
      :sliding_window ->
        get_sliding_window_status(redis_key, config, now)
      :fixed_window ->
        get_fixed_window_status(redis_key, config, now)
      :token_bucket ->
        get_token_bucket_status(redis_key, config, now)
    end
  end

  @spec reset(String.t()) :: :ok
  def reset(key) do
    redis_key = build_redis_key(key)
    
    case RedisManager.command(["DEL", redis_key]) do
      {:ok, _} ->
        emit_telemetry(:rate_limit_reset, %{key: key})
        :ok
      {:error, reason} ->
        Logger.error("Failed to reset rate limit for key #{key}: #{inspect(reason)}")
        :ok
    end
  end

  defp build_redis_key(key) do
    "rate_ltd:limit:#{key}"
  end

  defp get_script_for_algorithm(:sliding_window), do: LuaScripts.sliding_window_script()
  defp get_script_for_algorithm(:fixed_window), do: LuaScripts.fixed_window_script()
  defp get_script_for_algorithm(:token_bucket), do: LuaScripts.sliding_window_script() # Use sliding window for now

  defp get_sliding_window_status(redis_key, config, now) do
    window_start = now - config.window_ms
    
    case RedisManager.pipeline([
      ["ZREMRANGEBYSCORE", redis_key, "-inf", window_start],
      ["ZCARD", redis_key]
    ]) do
      {:ok, [_removed, count]} ->
        remaining = max(0, config.limit - count)
        reset_at = DateTime.add(DateTime.utc_now(), config.window_ms, :millisecond)
        
        %{count: count, remaining: remaining, reset_at: reset_at}
        
      {:error, _reason} ->
        # Return default status on error
        %{count: 0, remaining: config.limit, reset_at: DateTime.utc_now()}
    end
  end

  defp get_fixed_window_status(redis_key, config, now) do
    window_start = div(now, config.window_ms) * config.window_ms
    window_key = "#{redis_key}:#{window_start}"
    
    case RedisManager.command(["GET", window_key]) do
      {:ok, nil} ->
        reset_at = DateTime.from_unix!(window_start + config.window_ms, :millisecond)
        %{count: 0, remaining: config.limit, reset_at: reset_at}
        
      {:ok, count_str} ->
        count = String.to_integer(count_str)
        remaining = max(0, config.limit - count)
        reset_at = DateTime.from_unix!(window_start + config.window_ms, :millisecond)
        
        %{count: count, remaining: remaining, reset_at: reset_at}
        
      {:error, _reason} ->
        %{count: 0, remaining: config.limit, reset_at: DateTime.utc_now()}
    end
  end

  defp get_token_bucket_status(redis_key, config, now) do
    # For now, use sliding window logic
    get_sliding_window_status(redis_key, config, now)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:rate_ltd, :rate_limiter, event], %{}, metadata)
  end
end
