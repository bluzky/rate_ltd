defmodule RateLtd.QueueManager do
  @moduledoc """
  Manages request queues when rate limits are exceeded.
  """

  alias RateLtd.{RedisManager, LuaScripts, QueueConfig, QueuedRequest}
  require Logger

  @type enqueue_result :: {:queued, String.t()} | {:rejected, atom()}
  @type dequeue_result :: {:ok, QueuedRequest.t()} | {:empty}
  @type status :: %{depth: non_neg_integer(), oldest_request_age_ms: non_neg_integer()}

  @spec enqueue(QueuedRequest.t(), QueueConfig.t()) :: enqueue_result()
  def enqueue(%QueuedRequest{} = request, %QueueConfig{} = config) do
    queue_key = build_queue_key(config.name)
    priority_queue_key = if config.enable_priority and request.priority > 1 do
      build_priority_queue_key(config.name, request.priority)
    else
      nil
    end
    
    expires_at = DateTime.to_unix(request.expires_at, :millisecond)
    request_data = QueuedRequest.serialize(request)
    
    script_args = [
      config.max_size,
      request_data,
      expires_at,
      request.priority,
      to_string(config.overflow_strategy)
    ]
    
    keys = if priority_queue_key do
      [queue_key, priority_queue_key]
    else
      [queue_key, ""]
    end
    
    case RedisManager.eval(LuaScripts.enqueue_script(), keys, script_args) do
      {:ok, [1, _position]} ->
        emit_telemetry(:request_enqueued, %{
          queue_name: config.name,
          request_id: request.id,
          priority: request.priority
        })
        {:queued, request.id}
        
      {:ok, [0, reason]} ->
        emit_telemetry(:request_rejected, %{
          queue_name: config.name,
          request_id: request.id,
          reason: reason
        })
        {:rejected, String.to_atom(reason)}
        
      {:error, reason} ->
        Logger.error("Failed to enqueue request #{request.id}: #{inspect(reason)}")
        emit_telemetry(:enqueue_error, %{
          queue_name: config.name,
          request_id: request.id,
          error: reason
        })
        {:rejected, :redis_error}
    end
  end

  @spec peek_next(String.t()) :: dequeue_result()
  def peek_next(queue_name) do
    queue_key = build_queue_key(queue_name)
    priority_queue_key = build_priority_queue_key(queue_name, 2) # Check high priority
    
    case RedisManager.command(["LINDEX", priority_queue_key, -1]) do
      {:ok, nil} ->
        # No priority items, check regular queue
        case RedisManager.command(["LINDEX", queue_key, -1]) do
          {:ok, nil} -> {:empty}
          {:ok, data} -> deserialize_request(data)
          {:error, _} -> {:empty}
        end
        
      {:ok, data} ->
        deserialize_request(data)
        
      {:error, _} ->
        {:empty}
    end
  end

  @spec dequeue(String.t()) :: dequeue_result()
  def dequeue(queue_name) do
    queue_key = build_queue_key(queue_name)
    priority_queue_key = build_priority_queue_key(queue_name, 2)
    
    case RedisManager.eval(LuaScripts.dequeue_script(), [priority_queue_key, queue_key], []) do
      {:ok, [nil, nil]} ->
        {:empty}
        
      {:ok, [data, queue_type]} when is_binary(data) ->
        case deserialize_request(data) do
          {:ok, request} ->
            emit_telemetry(:request_dequeued, %{
              queue_name: queue_name,
              request_id: request.id,
              queue_type: queue_type
            })
            {:ok, request}
            
          {:error, reason} ->
            Logger.error("Failed to deserialize request from queue #{queue_name}: #{inspect(reason)}")
            {:empty}
        end
        
      {:error, reason} ->
        Logger.error("Failed to dequeue from #{queue_name}: #{inspect(reason)}")
        {:empty}
    end
  end

  @spec get_status(String.t()) :: status()
  def get_status(queue_name) do
    queue_key = build_queue_key(queue_name)
    priority_queue_key = build_priority_queue_key(queue_name, 2)
    
    case RedisManager.pipeline([
      ["LLEN", queue_key],
      ["LLEN", priority_queue_key],
      ["LINDEX", queue_key, -1],
      ["LINDEX", priority_queue_key, -1]
    ]) do
      {:ok, [regular_count, priority_count, oldest_regular, oldest_priority]} ->
        total_depth = regular_count + priority_count
        oldest_age = calculate_oldest_age([oldest_regular, oldest_priority])
        
        %{depth: total_depth, oldest_request_age_ms: oldest_age}
        
      {:error, _reason} ->
        %{depth: 0, oldest_request_age_ms: 0}
    end
  end

  @spec cleanup_expired(String.t()) :: {:ok, non_neg_integer()}
  def cleanup_expired(queue_name) do
    now = System.system_time(:millisecond)
    queue_key = build_queue_key(queue_name)
    
    case RedisManager.eval(LuaScripts.cleanup_expired_script(), [queue_key], [now]) do
      {:ok, cleaned_count} ->
        if cleaned_count > 0 do
          emit_telemetry(:expired_requests_cleaned, %{
            queue_name: queue_name,
            cleaned_count: cleaned_count
          })
        end
        {:ok, cleaned_count}
        
      {:error, reason} ->
        Logger.error("Failed to cleanup expired requests in #{queue_name}: #{inspect(reason)}")
        {:ok, 0}
    end
  end

  @spec list_queues() :: {:ok, list(String.t())}
  def list_queues do
    pattern = "rate_ltd:queue:*"
    
    case RedisManager.command(["KEYS", pattern]) do
      {:ok, keys} ->
        queue_names = 
          keys
          |> Enum.map(&extract_queue_name/1)
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)
        
        {:ok, queue_names}
        
      {:error, reason} ->
        Logger.error("Failed to list queues: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp build_queue_key(queue_name) do
    "rate_ltd:queue:#{queue_name}"
  end

  defp build_priority_queue_key(queue_name, priority) do
    "rate_ltd:queue:#{queue_name}:p#{priority}"
  end

  defp deserialize_request(data) when is_binary(data) do
    QueuedRequest.deserialize(data)
  end
  defp deserialize_request(_), do: {:error, :invalid_data}

  defp calculate_oldest_age(items) do
    now = DateTime.utc_now()
    
    items
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&deserialize_request/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, request} -> request.queued_at end)
    |> Enum.map(&DateTime.diff(now, &1, :millisecond))
    |> Enum.max(fn -> 0 end)
  end

  defp extract_queue_name("rate_ltd:queue:" <> rest) do
    case String.split(rest, ":p", parts: 2) do
      [queue_name] -> queue_name
      [queue_name, _priority] -> queue_name
    end
  end
  defp extract_queue_name(_), do: nil

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:rate_ltd, :queue_manager, event], %{}, metadata)
  end
end
