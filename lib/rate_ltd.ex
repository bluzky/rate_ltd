defmodule RateLtd do
  @moduledoc """
  RateLtd - Elixir Redis Rate Limiter Library

  A distributed rate limiting library for Elixir applications with Redis backend and queueing capabilities.

  ## Usage

  Configure rate limits and queues:

      rate_configs = [
        RateLtd.RateLimitConfig.new("api:calls", 100, 60_000),
        RateLtd.RateLimitConfig.new("external_api", 50, 60_000)
      ]

      queue_configs = [
        RateLtd.QueueConfig.new("api:queue", max_size: 1000),
        RateLtd.QueueConfig.new("external_api:queue", max_size: 500)
      ]

      RateLtd.configure(rate_configs, queue_configs)

  Make rate-limited requests:

      # Blocking mode (default)
      case RateLtd.request("external_api", fn -> HTTPClient.get("/data") end) do
        {:ok, response} -> handle_success(response)
        {:error, reason} -> handle_error(reason)
      end

      # Async mode
      case RateLtd.request("external_api", fn -> HTTPClient.get("/data") end, %{async: true}) do
        {:ok, response} -> handle_success(response)
        {:queued, %{request_id: id}} -> wait_for_result(id)
        {:error, reason} -> handle_error(reason)
      end

  Check rate limits without executing:

      case RateLtd.check("external_api") do
        {:allow, remaining} -> proceed_with_request()
        {:deny, retry_after_ms} -> wait_or_handle_limit(retry_after_ms)
      end
  """

  alias RateLtd.{
    ConfigManager,
    RateLimiter,
    QueueManager,
    QueuedRequest,
    RequestOptions,
    RateLimitConfig,
    QueueConfig
  }

  @type request_result :: 
    {:ok, term()} | 
    {:error, :timeout | :queue_full | :rate_limited | :invalid_config | {:function_error, term()}}

  @type async_result :: 
    {:ok, term()} | 
    {:queued, %{request_id: String.t(), estimated_wait_ms: non_neg_integer()}} | 
    {:error, term()}

  @type check_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @type status :: %{
    rate_limit: map(),
    queue: map(),
    processor: map()
  }

  # Configuration API

  @doc """
  Configure rate limits and queues for the application.

  ## Parameters
  - rate_configs: List of RateLimitConfig structs
  - queue_configs: List of QueueConfig structs

  ## Example
      rate_configs = [
        RateLtd.RateLimitConfig.new("api:calls", 100, 60_000),
        RateLtd.RateLimitConfig.new("external_api", 50, 60_000)
      ]

      queue_configs = [
        RateLtd.QueueConfig.new("api:queue", max_size: 1000),
        RateLtd.QueueConfig.new("external_api:queue", max_size: 500)
      ]

      RateLtd.configure(rate_configs, queue_configs)
  """
  @spec configure(list(RateLimitConfig.t()), list(QueueConfig.t())) :: :ok | {:error, term()}
  def configure(rate_configs, queue_configs) do
    ConfigManager.configure(rate_configs, queue_configs)
  end

  # Primary API

  @doc """
  Execute a function with rate limiting. Blocks until the function can be executed.

  ## Parameters
  - api_key: String identifier for the rate limit configuration
  - function: Function to execute when rate limit allows
  - options: RequestOptions struct (optional)

  ## Options
  - timeout_ms: Maximum time to wait (default: 30,000ms)
  - priority: Queue priority level (default: 1)
  - async: Return immediately if queued (default: false)
  - max_retries: Immediate retries before queueing (default: 3)

  ## Examples

      # Basic blocking request
      {:ok, result} = RateLtd.request("external_api", fn ->
        HTTPClient.get("/data")
      end)

      # With custom timeout
      {:ok, result} = RateLtd.request("external_api", fn ->
        HTTPClient.get("/data")
      end, %{timeout_ms: 60_000})

      # Async mode
      case RateLtd.request("external_api", fn -> HTTPClient.get("/data") end, %{async: true}) do
        {:ok, result} -> handle_immediate_result(result)
        {:queued, %{request_id: id}} -> wait_for_async_result(id)
      end
  """
  @spec request(String.t(), function()) :: request_result()
  @spec request(String.t(), function(), map() | RequestOptions.t()) :: request_result() | async_result()
  def request(api_key, function, options \\ %{})

  def request(api_key, function, options) when is_map(options) do
    options = 
      if is_struct(options) do
        options
      else
        RequestOptions.new(Map.to_list(options))
      end

    with {:ok, validated_options} <- RequestOptions.validate(options),
         {:ok, rate_config} <- get_or_create_rate_config(api_key),
         {:ok, queue_config} <- get_or_create_queue_config(api_key) do

      if validated_options.async do
        request_async(api_key, function, validated_options, rate_config, queue_config)
      else
        request_blocking(api_key, function, validated_options, rate_config, queue_config)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a request would be allowed without executing the function.

  ## Parameters
  - api_key: String identifier for the rate limit configuration

  ## Returns
  - `{:allow, remaining}` if the request would be allowed
  - `{:deny, retry_after_ms}` if the request would be rate limited

  ## Example
      case RateLtd.check("external_api") do
        {:allow, remaining} -> 
          # Make your call manually
          HTTPClient.get("/data")
        {:deny, retry_after_ms} -> 
          # Wait or handle rate limit
          Process.sleep(retry_after_ms)
      end
  """
  @spec check(String.t()) :: check_result()
  def check(api_key) do
    case get_or_create_rate_config(api_key) do
      {:ok, rate_config} ->
        RateLimiter.check_rate(api_key, rate_config)
      {:error, _reason} ->
        # Default to allowing if no config
        {:allow, 1000}
    end
  end

  @doc """
  Get comprehensive status for an API key including rate limit, queue, and processor information.

  ## Parameters
  - api_key: String identifier for the configuration

  ## Returns
  Status map with rate_limit, queue, and processor information.

  ## Example
      status = RateLtd.get_status("external_api")
      IO.inspect(status.rate_limit.remaining)
      IO.inspect(status.queue.depth)
  """
  @spec get_status(String.t()) :: status()
  def get_status(api_key) do
    rate_limit_status = 
      case get_or_create_rate_config(api_key) do
        {:ok, rate_config} -> RateLimiter.get_status(api_key, rate_config)
        {:error, _} -> %{count: 0, remaining: 0, reset_at: DateTime.utc_now()}
      end

    queue_status = 
      case get_or_create_queue_config(api_key) do
        {:ok, _queue_config} -> QueueManager.get_status("#{api_key}:queue")
        {:error, _} -> %{depth: 0, oldest_request_age_ms: 0}
      end

    processor_status = RateLtd.QueueProcessor.get_status()

    %{
      rate_limit: rate_limit_status,
      queue: queue_status,
      processor: processor_status
    }
  end

  # Private functions

  defp request_blocking(api_key, function, options, rate_config, queue_config) do
    case attempt_immediate_execution(api_key, function, options, rate_config) do
      {:ok, result} -> 
        {:ok, result}
      
      {:retry_exhausted} ->
        # Queue the request and wait for completion
        queue_and_wait(api_key, function, options, queue_config)
    end
  end

  defp request_async(api_key, function, options, rate_config, queue_config) do
    case attempt_immediate_execution(api_key, function, options, rate_config) do
      {:ok, result} -> 
        {:ok, result}
      
      {:retry_exhausted} ->
        # Queue the request for async processing
        queue_async(api_key, function, options, queue_config)
    end
  end

  defp attempt_immediate_execution(api_key, function, options, rate_config) do
    attempt_execution(api_key, function, rate_config, options.max_retries)
  end

  defp attempt_execution(_api_key, _function, _rate_config, 0) do
    # No more retries, need to queue
    {:retry_exhausted}
  end

  defp attempt_execution(api_key, function, rate_config, retries_left) do
    case RateLimiter.check_rate(api_key, rate_config) do
      {:allow, _remaining} ->
        try do
          result = function.()
          {:ok, result}
        rescue
          error -> {:error, {:function_error, error}}
        end
        
      {:deny, retry_after_ms} ->
        if retries_left > 0 and retry_after_ms < 1000 do
          # Short delay, retry immediately
          Process.sleep(retry_after_ms)
          attempt_execution(api_key, function, rate_config, retries_left - 1)
        else
          {:retry_exhausted}
        end
    end
  end

  defp queue_and_wait(api_key, function, options, queue_config) do
    queue_name = "#{api_key}:queue"
    
    request = QueuedRequest.new(queue_name, api_key, function, [
      timeout_ms: options.timeout_ms,
      priority: options.priority,
      caller_pid: self(),
      caller_ref: nil
    ])

    case QueueManager.enqueue(request, queue_config) do
      {:queued, _request_id} ->
        request_id = request.id
        receive do
          {:rate_ltd_result, ^request_id, result} -> result
          {:rate_ltd_expired, ^request_id, :timeout} -> {:error, :timeout}
        after
          options.timeout_ms -> {:error, :timeout}
        end
        
      {:rejected, reason} ->
        {:error, reason}
    end
  end

  defp queue_async(api_key, function, options, queue_config) do
    queue_name = "#{api_key}:queue"
    
    request = QueuedRequest.new(queue_name, api_key, function, [
      timeout_ms: options.timeout_ms,
      priority: options.priority,
      caller_pid: self(),
      caller_ref: nil
    ])

    case QueueManager.enqueue(request, queue_config) do
      {:queued, request_id} ->
        # Estimate wait time based on queue depth and rate limit
        estimated_wait = estimate_wait_time(api_key, queue_config)
        {:queued, %{request_id: request_id, estimated_wait_ms: estimated_wait}}
        
      {:rejected, reason} ->
        {:error, reason}
    end
  end

  defp estimate_wait_time(api_key, _queue_config) do
    # Simple estimation based on current queue depth and rate limit
    case {QueueManager.get_status("#{api_key}:queue"), get_or_create_rate_config(api_key)} do
      {%{depth: depth}, {:ok, %{window_ms: window_ms, limit: limit}}} ->
        # Rough estimate: (queue_depth / rate_limit) * window_ms
        div(depth * window_ms, max(limit, 1))
        
      _ ->
        30_000 # Default 30 second estimate
    end
  end

  defp get_or_create_rate_config(api_key) do
    case ConfigManager.get_rate_limit_config(api_key) do
      {:ok, config} -> 
        {:ok, config}
        
      {:error, :not_found} ->
        # Create default configuration
        defaults = Application.get_env(:rate_ltd, :defaults, [])
        
        config = RateLimitConfig.new(
          api_key,
          Keyword.get(defaults, :rate_limit, 100),
          Keyword.get(defaults, :rate_limit_window_ms, 60_000)
        )
        
        case ConfigManager.add_rate_limit_config(config) do
          :ok -> {:ok, config}
          error -> error
        end
    end
  end

  defp get_or_create_queue_config(api_key) do
    queue_name = "#{api_key}:queue"
    
    case ConfigManager.get_queue_config(queue_name) do
      {:ok, config} -> 
        {:ok, config}
        
      {:error, :not_found} ->
        # Create default configuration
        defaults = Application.get_env(:rate_ltd, :defaults, [])
        
        config = QueueConfig.new(queue_name, [
          max_size: Keyword.get(defaults, :max_queue_size, 1000),
          request_timeout_ms: Keyword.get(defaults, :queue_timeout_ms, 300_000)
        ])
        
        case ConfigManager.add_queue_config(config) do
          :ok -> {:ok, config}
          error -> error
        end
    end
  end
end
