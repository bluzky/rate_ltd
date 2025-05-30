defmodule RateLtd.SimpleRedisManager do
  @moduledoc """
  Simplified Redis manager without poolboy dependency.
  Uses a single persistent connection per process.
  """

  use GenServer
  require Logger

  @default_config [
    host: "localhost",
    port: 6379,
    database: 0,
    timeout: 5_000
  ]

  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec command(list()) :: {:ok, term()} | {:error, term()}
  def command(command) do
    GenServer.call(__MODULE__, {:command, command})
  end

  @spec pipeline(list()) :: {:ok, list()} | {:error, term()}
  def pipeline(commands) do
    GenServer.call(__MODULE__, {:pipeline, commands})
  end

  @spec eval(String.t(), list(), list()) :: {:ok, term()} | {:error, term()}
  def eval(script, keys, args) do
    command = ["EVAL", script, length(keys)] ++ keys ++ args
    GenServer.call(__MODULE__, {:command, command})
  end

  @impl true
  def init(config) do
    config = Keyword.merge(@default_config, config)
    
    case Redix.start_link(config) do
      {:ok, conn} ->
        Logger.info("RateLtd Redis connection started successfully")
        {:ok, %{conn: conn, config: config}}
      {:error, reason} ->
        Logger.error("Failed to start Redis connection: #{inspect(reason)}")
        # In test environment, continue without Redis
        if Mix.env() == :test do
          Logger.warning("Starting in test mode without Redis connection")
          {:ok, %{conn: nil, config: config, redis_available: false}}
        else
          {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call({:command, command}, _from, %{conn: nil} = state) do
    # Redis not available (test mode)
    {:reply, {:error, :redis_unavailable}, state}
  end

  def handle_call({:command, command}, _from, %{conn: conn} = state) do
    result = Redix.command(conn, command)
    {:reply, result, state}
  end

  def handle_call({:pipeline, commands}, _from, %{conn: nil} = state) do
    {:reply, {:error, :redis_unavailable}, state}
  end

  def handle_call({:pipeline, commands}, _from, %{conn: conn} = state) do
    result = Redix.pipeline(conn, commands)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      config: state.config,
      redis_available: Map.get(state, :redis_available, true),
      connection_alive: state.conn != nil and Process.alive?(state.conn)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, conn, reason}, %{conn: conn} = state) do
    Logger.error("Redis connection died: #{inspect(reason)}, reconnecting...")
    
    case Redix.start_link(state.config) do
      {:ok, new_conn} ->
        Logger.info("Redis reconnected successfully")
        {:noreply, %{state | conn: new_conn}}
      {:error, reason} ->
        Logger.error("Failed to reconnect to Redis: #{inspect(reason)}")
        # Retry after 5 seconds
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, %{state | conn: nil}}
    end
  end

  def handle_info(:reconnect, state) do
    case Redix.start_link(state.config) do
      {:ok, new_conn} ->
        Logger.info("Redis reconnected successfully")
        {:noreply, %{state | conn: new_conn}}
      {:error, reason} ->
        Logger.error("Failed to reconnect to Redis: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
