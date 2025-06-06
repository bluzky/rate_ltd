# lib/rate_ltd/queue.ex
defmodule RateLtd.Queue do
  @moduledoc """
  Simple queue management using Redis lists.
  """

  def enqueue(request, config) do
    queue_key = "rate_ltd:queue:#{request.queue_name}"
    request_data = Jason.encode!(request)

    # Check queue size and add atomically
    script = """
    local queue_key = KEYS[1]
    local max_size = tonumber(ARGV[1])
    local request_data = ARGV[2]

    local current_size = redis.call('LLEN', queue_key)

    if current_size >= max_size then
      return {0, 'queue_full'}
    end

    local position = redis.call('LPUSH', queue_key, request_data)
    return {1, position}
    """

    case RateLtd.Redis.eval(script, [queue_key], [config.max_queue_size, request_data]) do
      {:ok, [1, position]} -> {:ok, position}
      {:ok, [0, _reason]} -> {:error, :queue_full}
      {:error, reason} -> {:error, reason}
    end
  end

  def peek_next(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case RateLtd.Redis.command(["LINDEX", queue_key, -1]) do
      {:ok, nil} -> {:empty}
      {:ok, data} -> decode_request(data)
      {:error, _} -> {:empty}
    end
  end

  def dequeue(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case RateLtd.Redis.command(["RPOP", queue_key]) do
      {:ok, nil} -> {:empty}
      {:ok, data} -> decode_request(data)
      {:error, _} -> {:empty}
    end
  end

  def list_active_queues do
    case RateLtd.Redis.command(["KEYS", "rate_ltd:queue:*"]) do
      {:ok, keys} ->
        keys
        |> Enum.map(&extract_queue_name/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp decode_request(data) do
    case Jason.decode(data) do
      {:ok, request} -> {:ok, request}
      {:error, _} -> {:error, :invalid_data}
    end
  end

  defp extract_queue_name("rate_ltd:queue:" <> queue_name), do: queue_name
  defp extract_queue_name(_), do: nil
end
