# lib/rate_ltd/queue.ex
defmodule RateLtd.Queue do
  @moduledoc """
  Enhanced queue management using Redis lists with support for
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

  @spec get_queue_length(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_queue_length(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case redis_module().command(["LLEN", queue_key]) do
      {:ok, length} -> {:ok, length}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_expired_requests(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def remove_expired_requests(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"
    now = System.system_time(:millisecond)

    # Remove expired requests from the queue
    cleanup_script = """
    local queue_key = KEYS[1]
    local now = tonumber(ARGV[1])
    local removed = 0

    -- Get all items in the queue
    local items = redis.call('LRANGE', queue_key, 0, -1)

    -- Clear the queue
    redis.call('DEL', queue_key)

    -- Re-add non-expired items
    for i = 1, #items do
      local item_data = items[i]
      local success, item = pcall(cjson.decode, item_data)

      if success and item.expires_at and item.expires_at > now then
        redis.call('LPUSH', queue_key, item_data)
      else
        removed = removed + 1
      end
    end

    -- Restore queue order by reversing
    if redis.call('LLEN', queue_key) > 0 then
      local temp_items = redis.call('LRANGE', queue_key, 0, -1)
      redis.call('DEL', queue_key)
      for i = #temp_items, 1, -1 do
        redis.call('LPUSH', queue_key, temp_items[i])
      end
    end

    return removed
    """

    case redis_module().eval(cleanup_script, [queue_key], [now]) do
      {:ok, removed_count} -> {:ok, removed_count}
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

  @spec get_queue_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_queue_stats(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"
    now = System.system_time(:millisecond)

    stats_script = """
    local queue_key = KEYS[1]
    local now = tonumber(ARGV[1])

    local length = redis.call('LLEN', queue_key)

    if length == 0 then
      return {0, 0, 0, 0, 0}
    end

    local items = redis.call('LRANGE', queue_key, 0, -1)
    local expired = 0
    local total_wait_time = 0
    local oldest_queued = now
    local newest_queued = 0

    for i = 1, #items do
      local success, item = pcall(cjson.decode, items[i])
      if success and item.queued_at then
        local queued_at = tonumber(item.queued_at)
        local expires_at = tonumber(item.expires_at or 0)

        if expires_at > 0 and expires_at <= now then
          expired = expired + 1
        end

        total_wait_time = total_wait_time + (now - queued_at)
        oldest_queued = math.min(oldest_queued, queued_at)
        newest_queued = math.max(newest_queued, queued_at)
      end
    end

    local avg_wait_time = 0
    if length > 0 then
      avg_wait_time = total_wait_time / length
    end

    return {length, expired, avg_wait_time, oldest_queued, newest_queued}
    """

    case redis_module().eval(stats_script, [queue_key], [now]) do
      {:ok, [length, expired, avg_wait_time, oldest_queued, newest_queued]} ->
        {:ok,
         %{
           queue_name: queue_name,
           length: length,
           expired_count: expired,
           avg_wait_time_ms: avg_wait_time,
           oldest_request_age_ms: if(oldest_queued < now, do: now - oldest_queued, else: 0),
           newest_request_age_ms: if(newest_queued > 0, do: now - newest_queued, else: 0)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec clear_queue(String.t()) :: :ok
  def clear_queue(queue_name) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    case redis_module().command(["DEL", queue_key]) do
      {:ok, _} -> :ok
      # Fail silently for idempotency
      {:error, _} -> :ok
    end
  end

  @spec get_queue_position(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:not_found} | {:error, term()}
  def get_queue_position(queue_name, request_id) do
    queue_key = "rate_ltd:queue:#{queue_name}"

    position_script = """
    local queue_key = KEYS[1]
    local target_id = ARGV[1]

    local items = redis.call('LRANGE', queue_key, 0, -1)

    for i = 1, #items do
      local success, item = pcall(cjson.decode, items[i])
      if success and item.id == target_id then
        return #items - i + 1  -- Position from the end (next to be dequeued)
      end
    end

    return -1  -- Not found
    """

    case redis_module().eval(position_script, [queue_key], [request_id]) do
      {:ok, -1} -> {:not_found}
      {:ok, position} -> {:ok, position}
      {:error, reason} -> {:error, reason}
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
