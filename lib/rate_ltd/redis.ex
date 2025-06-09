# lib/rate_ltd/redis.ex
defmodule RateLtd.Redis do
  @moduledoc """
  Simple Redis wrapper with connection pooling.

  Provides a clean interface for Redis operations using Redix with
  connection pooling via Poolboy. Handles connection management,
  error handling, and provides both basic commands and Lua script execution.

  ## Configuration

  Configure Redis connection in your application config:

      config :rate_ltd, :redis,
        host: "localhost",
        port: 6379,
        database: 0,
        pool_size: 5

  ## Connection Pooling

  Uses Poolboy for connection pooling to:
  - Limit concurrent connections to Redis
  - Reuse connections efficiently
  - Handle connection failures gracefully
  - Prevent connection exhaustion

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, reason}` tuples
  for consistent error handling across the application.
  """
  use GenServer

  @doc """
  Starts the Redis GenServer and connection pool.

  Initializes the connection pool with the provided configuration
  and starts the GenServer for managing the pool lifecycle.

  ## Parameters

    * `config` - Keyword list of Redis configuration options
      - `:host` - Redis server hostname (default: "localhost")
      - `:port` - Redis server port (default: 6379)
      - `:database` - Redis database number (default: 0)
      - `:pool_size` - Number of connections in pool (default: 5)

  ## Returns

    * `{:ok, pid}` - Successfully started
    * `{:error, reason}` - Failed to start

  ## Examples

      iex> config = [host: "redis.example.com", port: 6379, pool_size: 10]
      iex> RateLtd.Redis.start_link(config)
      {:ok, #PID<0.123.0>}
  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Executes a Redis command using a connection from the pool.

  Automatically handles connection checkout/checkin and provides
  a simple interface for Redis operations.

  ## Parameters

    * `cmd` - List representing the Redis command and arguments

  ## Returns

    * `{:ok, result}` - Command executed successfully
    * `{:error, reason}` - Command failed or connection error

  ## Examples

      # String operations
      iex> RateLtd.Redis.command(["SET", "key", "value"])
      {:ok, "OK"}

      iex> RateLtd.Redis.command(["GET", "key"])
      {:ok, "value"}

      # Sorted set operations (used for rate limiting)
      iex> RateLtd.Redis.command(["ZADD", "rate_bucket", "1634567890123", "req_id_1"])
      {:ok, 1}

      iex> RateLtd.Redis.command(["ZCARD", "rate_bucket"])
      {:ok, 1}

      # Atomic operations
      iex> RateLtd.Redis.command(["INCR", "counter"])
      {:ok, 1}

  ## Connection Pooling

  Each command automatically:
  1. Checks out a connection from the pool
  2. Executes the command
  3. Returns the connection to the pool
  4. Returns the result or error
  """
  def command(cmd) do
    :poolboy.transaction(__MODULE__.Pool, fn conn ->
      Redix.command(conn, cmd)
    end)
  end

  @doc """
  Executes a Lua script on Redis with automatic connection management.

  Provides a convenient interface for running Lua scripts, which are
  essential for atomic rate limiting operations.

  ## Parameters

    * `script` - Lua script source code as string
    * `keys` - List of Redis keys the script will access
    * `args` - List of additional arguments for the script

  ## Returns

    * `{:ok, result}` - Script executed successfully
    * `{:error, reason}` - Script failed or connection error

  ## Examples

      # Simple Lua script
      iex> script = "return redis.call('GET', KEYS[1])"
      iex> RateLtd.Redis.eval(script, ["mykey"], [])
      {:ok, "value"}

      # Rate limiting script (simplified)
      iex> script = '''
      ...> local count = redis.call('ZCARD', KEYS[1])
      ...> if count < tonumber(ARGV[1]) then
      ...>   return 1
      ...> else
      ...>   return 0
      ...> end
      ...> '''
      iex> RateLtd.Redis.eval(script, ["rate_bucket"], ["100"])
      {:ok, 1}

  ## Lua Script Benefits

  - **Atomicity**: Entire script executes as single atomic operation
  - **Performance**: Reduces network round trips
  - **Consistency**: Prevents race conditions in complex operations
  - **Server-side logic**: Offloads computation to Redis server

  ## Use Cases in Rate Limiting

  - Sliding window calculations
  - Atomic check-and-increment operations
  - Cleanup of expired entries
  - Complex rate limiting algorithms
  """
  def eval(script, keys, args) do
    :poolboy.transaction(__MODULE__.Pool, fn conn ->
      Redix.command(conn, ["EVAL", script, length(keys)] ++ keys ++ args)
    end)
  end

  def init(config) do
    config = Keyword.merge(default_config(), config)

    pool_config = [
      name: {:local, __MODULE__.Pool},
      worker_module: Redix,
      size: config[:pool_size],
      max_overflow: 0
    ]

    worker_config = [
      host: config[:host],
      port: config[:port],
      database: config[:database]
    ]

    case :poolboy.start_link(pool_config, worker_config) do
      {:ok, _pool} -> {:ok, config}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  # Default configuration values for Redis connection
  defp default_config do
    [
      host: "localhost",
      port: 6379,
      database: 0,
      pool_size: 5
    ]
  end
end
