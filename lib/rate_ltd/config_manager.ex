defmodule RateLtd.ConfigManager do
  @moduledoc """
  Manages rate limit and queue configurations.
  """

  use GenServer
  alias RateLtd.{RateLimitConfig, QueueConfig}
  require Logger

  defstruct [
    :rate_configs,
    :queue_configs
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec configure(list(RateLimitConfig.t()), list(QueueConfig.t())) :: :ok | {:error, term()}
  def configure(rate_configs, queue_configs) do
    GenServer.call(__MODULE__, {:configure, rate_configs, queue_configs})
  end

  @spec add_rate_limit_config(RateLimitConfig.t()) :: :ok | {:error, term()}
  def add_rate_limit_config(%RateLimitConfig{} = config) do
    GenServer.call(__MODULE__, {:add_rate_limit_config, config})
  end

  @spec add_queue_config(QueueConfig.t()) :: :ok | {:error, term()}
  def add_queue_config(%QueueConfig{} = config) do
    GenServer.call(__MODULE__, {:add_queue_config, config})
  end

  @spec get_rate_limit_config(String.t()) :: {:ok, RateLimitConfig.t()} | {:error, :not_found}
  def get_rate_limit_config(key) do
    GenServer.call(__MODULE__, {:get_rate_limit_config, key})
  end

  @spec get_queue_config(String.t()) :: {:ok, QueueConfig.t()} | {:error, :not_found}
  def get_queue_config(name) do
    GenServer.call(__MODULE__, {:get_queue_config, name})
  end

  @spec list_rate_limit_configs() :: list(RateLimitConfig.t())
  def list_rate_limit_configs do
    GenServer.call(__MODULE__, :list_rate_limit_configs)
  end

  @spec list_queue_configs() :: list(QueueConfig.t())
  def list_queue_configs do
    GenServer.call(__MODULE__, :list_queue_configs)
  end

  @spec remove_rate_limit_config(String.t()) :: :ok
  def remove_rate_limit_config(key) do
    GenServer.call(__MODULE__, {:remove_rate_limit_config, key})
  end

  @spec remove_queue_config(String.t()) :: :ok
  def remove_queue_config(name) do
    GenServer.call(__MODULE__, {:remove_queue_config, name})
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      rate_configs: %{},
      queue_configs: %{}
    }
    
    # Load configurations from application environment if available
    state = load_initial_configs(state)
    
    Logger.info("ConfigManager started successfully")
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, rate_configs, queue_configs}, _from, state) do
    with {:ok, validated_rate_configs} <- validate_rate_configs(rate_configs),
         {:ok, validated_queue_configs} <- validate_queue_configs(queue_configs) do
      
      rate_config_map = Map.new(validated_rate_configs, &{&1.key, &1})
      queue_config_map = Map.new(validated_queue_configs, &{&1.name, &1})
      
      new_state = %{state | 
        rate_configs: rate_config_map,
        queue_configs: queue_config_map
      }
      
      Logger.info("Configured #{map_size(rate_config_map)} rate limits and #{map_size(queue_config_map)} queues")
      {:reply, :ok, new_state}
    else
      {:error, reason} ->
        Logger.error("Configuration failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_rate_limit_config, config}, _from, state) do
    case RateLimitConfig.validate(config) do
      {:ok, validated_config} ->
        new_rate_configs = Map.put(state.rate_configs, validated_config.key, validated_config)
        new_state = %{state | rate_configs: new_rate_configs}
        {:reply, :ok, new_state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_queue_config, config}, _from, state) do
    case QueueConfig.validate(config) do
      {:ok, validated_config} ->
        new_queue_configs = Map.put(state.queue_configs, validated_config.name, validated_config)
        new_state = %{state | queue_configs: new_queue_configs}
        {:reply, :ok, new_state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_rate_limit_config, key}, _from, state) do
    case Map.get(state.rate_configs, key) do
      nil -> {:reply, {:error, :not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  @impl true
  def handle_call({:get_queue_config, name}, _from, state) do
    case Map.get(state.queue_configs, name) do
      nil -> {:reply, {:error, :not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  @impl true
  def handle_call(:list_rate_limit_configs, _from, state) do
    configs = Map.values(state.rate_configs)
    {:reply, configs, state}
  end

  @impl true
  def handle_call(:list_queue_configs, _from, state) do
    configs = Map.values(state.queue_configs)
    {:reply, configs, state}
  end

  @impl true
  def handle_call({:remove_rate_limit_config, key}, _from, state) do
    new_rate_configs = Map.delete(state.rate_configs, key)
    new_state = %{state | rate_configs: new_rate_configs}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_queue_config, name}, _from, state) do
    new_queue_configs = Map.delete(state.queue_configs, name)
    new_state = %{state | queue_configs: new_queue_configs}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp load_initial_configs(state) do
    # Load from application environment
    rate_configs = Application.get_env(:rate_ltd, :rate_limits, [])
    queue_configs = Application.get_env(:rate_ltd, :queues, [])
    
    case {validate_rate_configs(rate_configs), validate_queue_configs(queue_configs)} do
      {{:ok, valid_rate_configs}, {:ok, valid_queue_configs}} ->
        rate_config_map = Map.new(valid_rate_configs, &{&1.key, &1})
        queue_config_map = Map.new(valid_queue_configs, &{&1.name, &1})
        
        %{state |
          rate_configs: rate_config_map,
          queue_configs: queue_config_map
        }
        
      _ ->
        Logger.warning("Failed to load initial configurations from application environment")
        state
    end
  end

  defp validate_rate_configs(configs) do
    validated = 
      configs
      |> Enum.map(&ensure_rate_limit_config/1)
      |> Enum.map(&RateLimitConfig.validate/1)
      |> Enum.reduce_while([], fn
        {:ok, config}, acc -> {:cont, [config | acc]}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)
    
    case validated do
      {:error, reason} -> {:error, reason}
      configs -> {:ok, Enum.reverse(configs)}
    end
  end

  defp validate_queue_configs(configs) do
    validated = 
      configs
      |> Enum.map(&ensure_queue_config/1)
      |> Enum.map(&QueueConfig.validate/1)
      |> Enum.reduce_while([], fn
        {:ok, config}, acc -> {:cont, [config | acc]}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)
    
    case validated do
      {:error, reason} -> {:error, reason}
      configs -> {:ok, Enum.reverse(configs)}
    end
  end

  defp ensure_rate_limit_config(%RateLimitConfig{} = config), do: config
  defp ensure_rate_limit_config({key, opts}) when is_binary(key) and is_list(opts) do
    %RateLimitConfig{
      key: key,
      limit: Keyword.get(opts, :limit, 100),
      window_ms: Keyword.get(opts, :window_ms, 60_000),
      algorithm: Keyword.get(opts, :algorithm, :sliding_window)
    }
  end
  defp ensure_rate_limit_config(config) when is_map(config) do
    struct(RateLimitConfig, config)
  end

  defp ensure_queue_config(%QueueConfig{} = config), do: config
  defp ensure_queue_config({name, opts}) when is_binary(name) and is_list(opts) do
    QueueConfig.new(name, opts)
  end
  defp ensure_queue_config(config) when is_map(config) do
    struct(QueueConfig, config)
  end
end
