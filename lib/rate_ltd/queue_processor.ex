# lib/rate_ltd/queue_processor.ex
defmodule RateLtd.QueueProcessor do
  @moduledoc """
  Local queue processor with lightweight parallel signaling by rate limit key.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, [], name: opts[:name] || __MODULE__)
  end

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_queues, state) do
    process_local_queue_parallel()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    interval = Application.get_env(:rate_ltd, :queue_check_interval, 1000)
    Process.send_after(self(), :check_queues, interval)
  end

  # NEW: Parallel processing by rate limit key
  defp process_local_queue_parallel do
    # Get batch of requests from queue
    requests = RateLtd.LocalQueue.get_next_batch(50)

    if length(requests) > 0 do
      # Group requests by rate limit key
      grouped = Enum.group_by(requests, fn req -> req["rate_limit_key"] end)

      # Process each key group in parallel
      grouped
      |> Enum.map(fn {key, key_requests} ->
        Task.async(fn -> process_key_signals(key, key_requests) end)
      end)
      # 5 second timeout for all tasks
      |> Task.await_many(5000)
    end
  end

  # Process requests for a specific rate limit key (sequentially within key)
  defp process_key_signals(key, requests) do
    config = RateLtd.ConfigManager.get_config(key)

    # Process requests for this key until rate limited
    Enum.reduce_while(requests, :continue, fn request, _acc ->
      cond do
        request_expired?(request) ->
          RateLtd.LocalQueue.dequeue_specific(request["id"])
          {:cont, :continue}

        true ->
          case RateLtd.Limiter.check_rate(key, config) do
            {:allow, _remaining} ->
              signal_client_and_dequeue(request)
              {:cont, :continue}

            {:deny, _retry_after} ->
              # Stop processing this key
              {:halt, :stop}
          end
      end
    end)
  end

  defp signal_client_and_dequeue(request) do
    caller_pid = :erlang.binary_to_term(Base.decode64!(request["caller_pid"]))

    if is_pid(caller_pid) && Process.alive?(caller_pid) do
      send(caller_pid, {:rate_ltd_execute, request["id"]})
      RateLtd.LocalQueue.dequeue_specific(request["id"])
    else
      # Dead process, just remove from queue
      RateLtd.LocalQueue.dequeue_specific(request["id"])
    end
  end

  defp request_expired?(request) do
    now = System.system_time(:millisecond)
    expires_at = request["expires_at"]
    now > expires_at
  end
end
