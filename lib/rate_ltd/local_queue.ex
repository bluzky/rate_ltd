# lib/rate_ltd/local_queue.ex
defmodule RateLtd.LocalQueue do
  @moduledoc """
  Local queue management using ETS with Redis counters for metrics.

  Each node manages its own queue locally while maintaining global pending counters
  in Redis. This hybrid approach provides:

  - Fast local operations (ETS)
  - Global visibility (Redis counters)
  - Automatic cleanup of expired requests
  - Fault tolerance (local queues survive Redis outages)

  ## Queue Structure

  Requests are stored in ETS as `{timestamp, request_map}` tuples where:
  - `timestamp` is microsecond precision for ordering
  - `request_map` contains request details and metadata

  ## Redis Integration

  Global pending counters are maintained in Redis with keys:
  `rate_ltd:pending:{rate_limit_key}`

  These counters track total pending requests across all nodes
  for monitoring and capacity planning.
  """

  @table_name :rate_ltd_local_queue

  @doc """
  Initializes the local queue ETS table.

  Creates a named ETS table for storing queued requests. This should be called
  once during application startup.

  ## Table Properties

  - `:named_table` - Accessible by name across the application
  - `:public` - Multiple processes can read/write
  - `:ordered_set` - Maintains timestamp ordering for FIFO processing

  ## Examples

      iex> RateLtd.LocalQueue.init()
      :rate_ltd_local_queue
  """
  def init do
    :ets.new(@table_name, [:named_table, :public, :ordered_set])
  end

  @doc """
  Enqueues a request if there's capacity in the local queue.

  Adds a request to the local ETS queue and increments the global pending
  counter in Redis. Respects the maximum queue size to prevent memory issues.

  ## Parameters

    * `request` - Map containing request details, must include `"rate_limit_key"`
    * `config` - Configuration map with `:max_queue_size`

  ## Returns

    * `{:ok, queue_size}` - Request enqueued successfully
    * `{:error, :queue_full}` - Queue has reached maximum capacity

  ## Request Format

  The request map should contain:
  - `"rate_limit_key"` - The rate limit bucket key
  - `"id"` - Unique request identifier
  - `"caller_pid"` - Encoded PID for response delivery
  - `"expires_at"` - Expiration timestamp
  - Additional application-specific data

  ## Examples

      iex> request = %{
      ...>   "id" => "req_123",
      ...>   "rate_limit_key" => "bucket:api:user_456",
      ...>   "caller_pid" => pid |> :erlang.term_to_binary() |> Base.encode64(),
      ...>   "expires_at" => System.system_time(:millisecond) + 30_000
      ...> }
      iex> config = %{max_queue_size: 1000}
      iex> RateLtd.LocalQueue.enqueue(request, config)
      {:ok, 1}

  ## Side Effects

  - Increments Redis pending counter
  - Sets expiration on Redis counter (1 hour)
  """
  @spec enqueue(map(), map()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def enqueue(request, config) do
    # Check local queue size
    current_size = :ets.info(@table_name, :size)

    if current_size >= config.max_queue_size do
      {:error, :queue_full}
    else
      # Store locally with timestamp as key for ordering
      timestamp = System.system_time(:microsecond)
      :ets.insert(@table_name, {timestamp, request})

      # Increment Redis pending counter
      pending_key = "rate_ltd:pending:#{request["rate_limit_key"]}"
      redis_module().command(["INCR", pending_key])
      redis_module().command(["EXPIRE", pending_key, 3600])

      {:ok, current_size + 1}
    end
  end

  @doc """
  Peeks at the next request without removing it from the queue.

  Useful for inspecting the queue state or making decisions about
  processing without modifying the queue.

  ## Returns

    * `{:ok, request}` - Next request in queue (oldest first)
    * `{:empty}` - Queue is empty

  ## Examples

      iex> RateLtd.LocalQueue.peek_next()
      {:ok, %{"id" => "req_123", "rate_limit_key" => "bucket:api:user_456"}}

      iex> RateLtd.LocalQueue.peek_next()
      {:empty}
  """
  @spec peek_next() :: {:ok, map()} | {:empty}
  def peek_next do
    case :ets.first(@table_name) do
      :"$end_of_table" ->
        {:empty}

      key ->
        [{_timestamp, request}] = :ets.lookup(@table_name, key)
        {:ok, request}
    end
  end

  @doc """
  Removes and returns the next request from the queue.

  Dequeues the oldest request (FIFO) and decrements the global pending
  counter in Redis.

  ## Returns

    * `{:ok, request}` - Successfully dequeued request
    * `{:empty}` - Queue is empty

  ## Examples

      iex> RateLtd.LocalQueue.dequeue()
      {:ok, %{"id" => "req_123", "rate_limit_key" => "bucket:api:user_456"}}

      iex> RateLtd.LocalQueue.dequeue()
      {:empty}

  ## Side Effects

  - Decrements Redis pending counter
  """
  @spec dequeue() :: {:ok, map()} | {:empty}
  def dequeue do
    case :ets.first(@table_name) do
      :"$end_of_table" ->
        {:empty}

      key ->
        [{_timestamp, request}] = :ets.lookup(@table_name, key)
        :ets.delete(@table_name, key)

        # Decrement Redis pending counter
        pending_key = "rate_ltd:pending:#{request["rate_limit_key"]}"
        redis_module().command(["DECR", pending_key])

        {:ok, request}
    end
  end

  @doc """
  Returns the number of requests currently in the local queue.

  ## Returns

  Non-negative integer representing queue size.

  ## Examples

      iex> RateLtd.LocalQueue.count_local_pending()
      42
  """
  @spec count_local_pending() :: non_neg_integer()
  def count_local_pending do
    :ets.info(@table_name, :size)
  end

  @doc """
  Lists all unique rate limit keys currently in the local queue.

  Useful for monitoring which rate limit buckets have pending requests
  and for grouping operations.

  ## Returns

  List of unique rate limit key strings.

  ## Examples

      iex> RateLtd.LocalQueue.list_local_queue_keys()
      ["bucket:api:user_123", "bucket:payments:merchant_456", "simple:legacy_key"]
  """
  @spec list_local_queue_keys() :: [String.t()]
  def list_local_queue_keys do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_timestamp, request} -> request["rate_limit_key"] end)
    |> Enum.uniq()
  end

  @doc """
  Retrieves a batch of requests for batch processing.

  Returns up to `max_count` requests in queue order (oldest first)
  without removing them from the queue. Used by the queue processor
  for efficient batch operations.

  ## Parameters

    * `max_count` - Maximum number of requests to return (default: 20)

  ## Returns

  List of request maps in processing order.

  ## Examples

      iex> RateLtd.LocalQueue.get_next_batch(10)
      [
        %{"id" => "req_1", "rate_limit_key" => "bucket:api:user_123"},
        %{"id" => "req_2", "rate_limit_key" => "bucket:api:user_124"}
      ]

  ## Use Cases

  - Queue processor batch operations
  - Parallel processing by rate limit key
  - Monitoring and diagnostics
  """
  @spec get_next_batch(non_neg_integer()) :: [map()]
  def get_next_batch(max_count \\ 20) do
    :ets.tab2list(@table_name)
    |> Enum.take(max_count)
    |> Enum.map(fn {_timestamp, request} -> request end)
  end

  @doc """
  Removes a specific request from the queue by ID.

  Used for targeted removal when processing specific requests or
  cleaning up expired/cancelled requests.

  ## Parameters

    * `request_id` - Unique identifier of the request to remove

  ## Returns

    * `{:ok, request}` - Request found and removed
    * `{:error, :not_found}` - Request not in queue

  ## Examples

      iex> RateLtd.LocalQueue.dequeue_specific("req_123")
      {:ok, %{"id" => "req_123", "rate_limit_key" => "bucket:api:user_456"}}

      iex> RateLtd.LocalQueue.dequeue_specific("nonexistent")
      {:error, :not_found}

  ## Implementation Details

  Uses ETS select with pattern matching to efficiently find the request
  by ID without scanning the entire table.

  ## Side Effects

  - Decrements Redis pending counter if request found
  """
  @spec dequeue_specific(String.t()) :: {:ok, map()} | {:error, :not_found}
  def dequeue_specific(request_id) do
    # Find the request by ID using ETS select pattern matching
    # Pattern: match any timestamp with request containing the target ID
    match_pattern = {{:"$1", %{"id" => request_id}}, [], [{{:"$1", :"$_"}}]}

    case :ets.select(@table_name, [match_pattern]) do
      [{timestamp, {_timestamp, request}}] ->
        # Remove from ETS
        case :ets.delete(@table_name, timestamp) do
          true ->
            # Decrement Redis pending counter
            pending_key = "rate_ltd:pending:#{request["rate_limit_key"]}"
            redis_module().command(["DECR", pending_key])
            {:ok, request}

          false ->
            {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Groups all queued requests by their rate limit key.

  Returns a map where keys are rate limit keys and values are lists
  of requests for that key. Useful for analysis and batch operations.

  ## Returns

  Map of `rate_limit_key => [request_list]`

  ## Examples

      iex> RateLtd.LocalQueue.list_by_key()
      %{
        "bucket:api:user_123" => [%{"id" => "req_1"}, %{"id" => "req_2"}],
        "bucket:payments:merchant_456" => [%{"id" => "req_3"}]
      }

  ## Use Cases

  - Analytics and monitoring
  - Group-based processing decisions
  - Queue distribution analysis
  """
  @spec list_by_key() :: %{String.t() => [map()]}
  def list_by_key do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_timestamp, request} -> request end)
    |> Enum.group_by(fn req -> req["rate_limit_key"] end)
  end

  @doc """
  Counts queued requests grouped by rate limit key.

  Returns a map showing how many requests are pending for each
  rate limit key. More efficient than `list_by_key/0` when you
  only need counts.

  ## Returns

  Map of `rate_limit_key => count`

  ## Examples

      iex> RateLtd.LocalQueue.count_by_key()
      %{
        "bucket:api:user_123" => 5,
        "bucket:payments:merchant_456" => 2,
        "simple:legacy_key" => 1
      }

  ## Use Cases

  - Performance monitoring
  - Capacity planning
  - Load balancing decisions
  """
  @spec count_by_key() :: %{String.t() => non_neg_integer()}
  def count_by_key do
    list_by_key()
    |> Enum.map(fn {key, requests} -> {key, length(requests)} end)
    |> Enum.into(%{})
  end

  # Private functions

  @doc false
  # Returns the configured Redis module with fallback for testing
  defp redis_module do
    Application.get_env(:rate_ltd, :redis_module, RateLtd.Redis)
  end
end
