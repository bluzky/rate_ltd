# lib/rate_ltd/queue_processor.ex
defmodule RateLtd.QueueProcessor do
  @moduledoc """
  Minimal queue processor that signals waiting processes.
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
    process_ready_requests()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    # Check every 2 seconds
    Process.send_after(self(), :check_queues, 2000)
  end

  defp process_ready_requests do
    RateLtd.Queue.list_active_queues()
    |> Enum.each(&try_process_queue/1)
  end

  defp try_process_queue(queue_name) do
    case RateLtd.Queue.peek_next(queue_name) do
      {:ok, request} ->
        if request_expired?(request) do
          # Remove expired request
          RateLtd.Queue.dequeue(queue_name)
          # Try next request
          try_process_queue(queue_name)
        else
          # Check if rate limit allows
          config = get_config(request["rate_limit_key"])

          case RateLtd.Limiter.check_rate(request["rate_limit_key"], config) do
            {:allow, _remaining} ->
              # Signal the waiting process
              caller_pid =
                request["caller_pid"] &&
                  :erlang.binary_to_term(Base.decode64!(request["caller_pid"]))

              if caller_pid && Process.alive?(caller_pid) do
                send(caller_pid, {:rate_ltd_execute, request["id"]})
                RateLtd.Queue.dequeue(queue_name)
                # Try next request
                try_process_queue(queue_name)
              else
                # Dead process, remove request
                RateLtd.Queue.dequeue(queue_name)
                try_process_queue(queue_name)
              end

            {:deny, _retry_after} ->
              # Still rate limited, leave in queue
              :ok
          end
        end

      {:empty} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp request_expired?(request) do
    now = System.system_time(:millisecond)
    expires_at = request["expires_at"]
    now > expires_at
  end

  defp get_config(key) do
    defaults = Application.get_env(:rate_ltd, :defaults, [])
    custom_configs = Application.get_env(:rate_ltd, :configs, %{})

    case Map.get(custom_configs, key) do
      nil ->
        %{
          limit: Keyword.get(defaults, :limit, 100),
          window_ms: Keyword.get(defaults, :window_ms, 60_000)
        }

      config when is_map(config) ->
        config

      {limit, window_ms} ->
        %{limit: limit, window_ms: window_ms}
    end
  end
end
