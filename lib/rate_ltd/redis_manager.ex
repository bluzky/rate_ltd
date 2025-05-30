defmodule RateLtd.RedisManager do
  @moduledoc """
  Manages Redis connections and provides connection pooling.
  """

  use GenServer
  require Logger

  @default_config [
    host: "localhost",
    port: 6379,
    database: 0,
    pool_size: 10,
    timeout: 5_000
  ]

  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get_connection() :: {:ok, pid()} | {:error, term()}
  def get_connection do
    try do
      case :poolboy.checkout(__MODULE__.Pool, false) do
        :full -> {:error, :pool_full}
        conn when is_pid(conn) -> {:ok, conn}
      end
    catch
      :exit, _ -> {:error, :no_pool}
    end
  end

  @spec return_connection(pid()) :: :ok
  def return_connection(conn) do
    :poolboy.checkin(__MODULE__.Pool, conn)
  end

  @spec command(list()) :: {:ok, term()} | {:error, term()}
  def command(command) do
    with_connection(fn conn ->
      Redix.command(conn, command)
    end)
  end

  @spec pipeline(list()) :: {:ok, list()} | {:error, term()}
  def pipeline(commands) do
    with_connection(fn conn ->
      Redix.pipeline(conn, commands)
    end)
  end

  @spec eval(String.t(), list(), list()) :: {:ok, term()} | {:error, term()}
  def eval(script, keys, args) do
    with_connection(fn conn ->
      Redix.command(conn, ["EVAL", script, length(keys)] ++ keys ++ args)
    end)
  end

  defp with_connection(fun) do
    case get_connection() do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          return_connection(conn)
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(config) do
    config = Keyword.merge(@default_config, config)
    
    pool_config = [
      name: {:local, __MODULE__.Pool},
      worker_module: Redix,
      size: config[:pool_size],
      max_overflow: 0
    ]

    worker_config = [
      host: config[:host],
      port: config[:port],
      database: config[:database],
      timeout: config[:timeout]
    ]

    case :poolboy.start_link(pool_config, worker_config) do
      {:ok, _pool} ->
        Logger.info("RateLtd Redis connection pool started successfully")
        {:ok, %{config: config}}
      {:error, reason} ->
        Logger.error("Failed to start Redis connection pool: #{inspect(reason)}")
        # In test environment, continue without Redis
        if Mix.env() == :test do
          Logger.warning("Starting in test mode without Redis connection pool")
          {:ok, %{config: config, redis_available: false}}
        else
          {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      config: state.config,
      pool_status: :poolboy.status(__MODULE__.Pool)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
