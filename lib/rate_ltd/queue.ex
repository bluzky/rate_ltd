# lib/rate_ltd/queue.ex
defmodule RateLtd.Queue do
  @moduledoc """
  Queue management using Redis lists with support for
  grouped buckets and priority queuing.
  """

  @type queue_request :: %{
          id: String.t(),
          queue_name: String.t(),
          rate_limit_key: String.t(),
          caller_pid: String.t(),
          queued_at: non_neg_integer(),
          expires_at: non_neg_integer(),
          priority: non_neg_integer()
        }

  @spec enqueue(map(), map()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def enqueue(request, config) do
    queue_key = "rate_ltd:queue:#{request.queue_name}"

    request_data =
      request
      |> Map.put_new(:priority, 0)
      |> Jason.encode!()

    # Check queue size and add atomically with priority support
    script = """
    local queue_key = KEYS[1]
    local max_size = tonumber(ARGV[1])
    local request_data = ARGV[2]
    local priority = tonumber(ARGV[3])

    local current_size = redis.call('LLEN', queue_key)

    if current_size >= max_size then
      return {0, 'queue_full'}
    end

    local position
    if priority > 0 then
      -- High priority: add to front
      position = redis.call('LPUSH', queue_key, request_data)
    else
      -- Normal priority: add to back
      position = redis.call('RPUSH', queue_key, request_data)
    end

    -- Set expiration for the queue
    redis.call('EXPIRE', queue_key, 3600)

    return {1, position}
    """

    priority = Map.get(request, :priority, 0)

    case redis_module().eval(script, [queue_key], [config.max_queue_size, request_data, priority]) do
      {:ok, [1, position]} -> {:ok, position}
      {:ok, [0, _reason]} -> {:error, :queue_full}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec peek_next(String.t()) :: {:ok, map()} | {:empty} | {:error, term()}
  def peek_next(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case redis_module().command(["LINDEX", queue_key, -1]) do
      {:ok, nil} -> {:empty}
      {:ok, data} -> decode_request(data)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dequeue(String.t()) :: {:ok, map()} | {:empty} | {:error, term()}
  def dequeue(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case redis_module().command(["RPOP", queue_key]) do
      {:ok, nil} -> {:empty}
      {:ok, data} -> decode_request(data)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_active_queues() :: [String.t()]
  def list_active_queues do
    case redis_module().command(["KEYS", "rate_ltd:queue:*"]) do
      {:ok, keys} ->
        keys
        |> Enum.map(&extract_queue_name/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # Private functions

  defp decode_request(data) do
    case Jason.decode(data) do
      {:ok, request} -> {:ok, request}
      {:error, _} -> {:error, :invalid_data}
    end
  end

  defp extract_queue_name("rate_ltd:queue:" <> queue_name), do: queue_name
  defp extract_queue_name(_), do: nil

  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
