defmodule RateLtd.QueueProcessor do
  @moduledoc """
  Background process that moves ready requests from queue back to rate limiter.
  """

  use GenServer
  alias RateLtd.{QueueManager, RateLimiter, ConfigManager, QueuedRequest}
  require Logger

  @default_config [
    polling_interval_ms: 1_000,
    batch_size: 100,
    enable_cleanup: true
  ]

  defstruct [
    :config,
    :timer_ref,
    :stats
  ]

  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get_status() :: %{
    queues_processed: non_neg_integer(),
    last_run: DateTime.t() | nil,
    active: boolean(),
    stats: map()
  }
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @spec pause() :: :ok
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @spec resume() :: :ok
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @impl true
  def init(config) do
    config = Keyword.merge(@default_config, config)
    
    state = %__MODULE__{
      config: config,
      timer_ref: nil,
      stats: %{
        queues_processed: 0,
        requests_processed: 0,
        last_run: nil,
        errors: 0,
        active: true
      }
    }
    
    # Start processing immediately
    {:ok, schedule_next_run(state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      queues_processed: state.stats.queues_processed,
      last_run: state.stats.last_run,
      active: state.stats.active,
      stats: state.stats
    }
    
    {:reply, status, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    state = 
      state
      |> cancel_timer()
      |> put_in([:stats, :active], false)
    
    Logger.info("Queue processor paused")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    state = 
      state
      |> put_in([:stats, :active], true)
      |> schedule_next_run()
    
    Logger.info("Queue processor resumed")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:process_queues, state) do
    if state.stats.active do
      state = process_all_queues(state)
      {:noreply, schedule_next_run(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
    :ok
  end

  defp schedule_next_run(state) do
    timer_ref = Process.send_after(self(), :process_queues, state.config[:polling_interval_ms])
    %{state | timer_ref: timer_ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp process_all_queues(state) do
    start_time = System.monotonic_time(:millisecond)
    
    try do
      case QueueManager.list_queues() do
        {:ok, queue_names} ->
          {processed_count, errors} = process_queues(queue_names)
          
          new_stats = %{
            state.stats |
            queues_processed: state.stats.queues_processed + length(queue_names),
            requests_processed: state.stats.requests_processed + processed_count,
            errors: state.stats.errors + errors,
            last_run: DateTime.utc_now()
          }
          
          emit_telemetry(:processing_completed, %{
            duration_ms: System.monotonic_time(:millisecond) - start_time,
            queues_count: length(queue_names),
            requests_processed: processed_count,
            errors: errors
          })
          
          %{state | stats: new_stats}
      end
    rescue
      error ->
        Logger.error("Queue processing failed: #{inspect(error)}")
        
        new_stats = %{
          state.stats |
          errors: state.stats.errors + 1,
          last_run: DateTime.utc_now()
        }
        
        %{state | stats: new_stats}
    end
  end

  defp process_queues(queue_names) do
    {processed_count, errors} = 
      queue_names
      |> Enum.reduce({0, 0}, fn queue_name, {processed_acc, errors_acc} ->
        case process_single_queue(queue_name) do
          {:ok, count} -> {processed_acc + count, errors_acc}
          {:error, _reason} -> {processed_acc, errors_acc + 1}
        end
      end)
    
    # Cleanup expired requests if enabled
    if Application.get_env(:rate_ltd, :processor, [])[:enable_cleanup] do
      Enum.each(queue_names, &QueueManager.cleanup_expired/1)
    end
    
    {processed_count, errors}
  end

  defp process_single_queue(queue_name) do
    try do
      count = process_queue_requests(queue_name, 0)
      {:ok, count}
    rescue
      error ->
        Logger.error("Failed to process queue #{queue_name}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp process_queue_requests(queue_name, processed_count) do
    case QueueManager.peek_next(queue_name) do
      {:empty} ->
        processed_count
        
      {:ok, %QueuedRequest{} = request} ->
        if QueuedRequest.expired?(request) do
          # Remove expired request and continue
          QueueManager.dequeue(queue_name)
          process_queue_requests(queue_name, processed_count)
        else
          case try_process_request(request) do
            :processed ->
              # Request was processed, remove from queue and continue
              QueueManager.dequeue(queue_name)
              process_queue_requests(queue_name, processed_count + 1)
              
            :rate_limited ->
              # Still rate limited, leave in queue and stop processing this queue
              processed_count
          end
        end
    end
  end

  defp try_process_request(%QueuedRequest{} = request) do
    case ConfigManager.get_rate_limit_config(request.rate_limit_key) do
      {:ok, rate_config} ->
        case RateLimiter.check_rate(request.rate_limit_key, rate_config) do
          {:allow, _remaining} ->
            execute_request(request)
            :processed
            
          {:deny, _retry_after} ->
            :rate_limited
        end
        
      {:error, _reason} ->
        # No configuration found, process the request anyway
        execute_request(request)
        :processed
    end
  end

  defp execute_request(%QueuedRequest{} = request) do
    try do
      result = request.function.()
      send_result_to_caller(request, {:ok, result})
      
      emit_telemetry(:request_executed, %{
        request_id: request.id,
        queue_name: request.queue_name,
        rate_limit_key: request.rate_limit_key
      })
      
    rescue
      error ->
        send_result_to_caller(request, {:error, {:function_error, error}})
        
        emit_telemetry(:request_execution_failed, %{
          request_id: request.id,
          queue_name: request.queue_name,
          error: inspect(error)
        })
    end
  end

  defp send_result_to_caller(%QueuedRequest{caller_pid: nil}, _result), do: :ok
  defp send_result_to_caller(%QueuedRequest{caller_pid: pid, id: id}, result) 
       when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:rate_ltd_result, id, result})
    end
  end
  defp send_result_to_caller(_, _), do: :ok

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:rate_ltd, :queue_processor, event], %{}, metadata)
  end
end
