defmodule RateLtd do
  @moduledoc """
  Simple rate limiter with Redis backend and minimal queueing.
  """

  @type result :: {:ok, term()} | {:error, term()}

  @spec request(String.t(), function()) :: result()
  @spec request(String.t(), function(), keyword()) :: result()
  def request(key, function, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_retries = Keyword.get(opts, :max_retries, 3)

    case attempt_with_retries(key, function, max_retries) do
      {:ok, result} -> {:ok, result}
      :rate_limited -> queue_and_wait(key, function, timeout_ms)
    end
  end

  @spec check(String.t()) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(key) do
    config = get_config(key)
    RateLtd.Limiter.check_rate(key, config)
  end

  @spec reset(String.t()) :: :ok
  def reset(key) do
    RateLtd.Limiter.reset(key)
  end

  # Private functions

  defp attempt_with_retries(key, function, retries_left) when retries_left > 0 do
    config = get_config(key)

    case RateLtd.Limiter.check_rate(key, config) do
      {:allow, _remaining} ->
        try do
          {:ok, function.()}
        rescue
          error -> {:error, {:function_error, error}}
        end

      {:deny, retry_after} when retry_after < 1000 ->
        Process.sleep(retry_after)
        attempt_with_retries(key, function, retries_left - 1)

      {:deny, _retry_after} ->
        :rate_limited
    end
  end

  defp attempt_with_retries(_key, _function, 0), do: :rate_limited

  defp queue_and_wait(key, function, timeout_ms) do
    queue_name = "#{key}:queue"
    config = get_config(key)
    request_id = generate_id()

    request = %{
      id: request_id,
      queue_name: queue_name,
      rate_limit_key: key,
      caller_pid: :erlang.term_to_binary(self()) |> Base.encode64(),
      queued_at: System.system_time(:millisecond),
      expires_at: System.system_time(:millisecond) + timeout_ms
    }

    case RateLtd.Queue.enqueue(request, config) do
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

  defp get_config(key) do
    defaults = Application.get_env(:rate_ltd, :defaults, [])
    custom_configs = Application.get_env(:rate_ltd, :configs, %{})

    case Map.get(custom_configs, key) do
      nil ->
        %{
          limit: Keyword.get(defaults, :limit, 100),
          window_ms: Keyword.get(defaults, :window_ms, 60_000),
          max_queue_size: Keyword.get(defaults, :max_queue_size, 1000)
        }

      config when is_map(config) ->
        config

      {limit, window_ms} ->
        %{
          limit: limit,
          window_ms: window_ms,
          max_queue_size: Keyword.get(defaults, :max_queue_size, 1000)
        }
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
end
