# test/test_helper.exs
ExUnit.start()

# Mock Redis for testing
defmodule MockRedis do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok, %{data: %{}, scripts: %{}}}
  end

  def command(cmd), do: GenServer.call(__MODULE__, {:command, cmd})
  def eval(script, keys, args), do: GenServer.call(__MODULE__, {:eval, script, keys, args})

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # Add debug function to see current state
  def debug_state do
    GenServer.call(__MODULE__, :debug_state)
  end

  def handle_call({:command, ["DEL", key]}, _from, state) do
    new_data = Map.delete(state.data, key)
    {:reply, {:ok, 1}, %{state | data: new_data}}
  end

  def handle_call({:command, ["LLEN", key]}, _from, state) do
    length =
      case Map.get(state.data, key) do
        nil -> 0
        list when is_list(list) -> length(list)
        _ -> 0
      end

    {:reply, {:ok, length}, state}
  end

  def handle_call({:command, ["LPUSH", key, value]}, _from, state) do
    list = Map.get(state.data, key, [])
    new_list = [value | list]
    new_data = Map.put(state.data, key, new_list)
    {:reply, {:ok, length(new_list)}, %{state | data: new_data}}
  end

  def handle_call({:command, ["RPOP", key]}, _from, state) do
    case Map.get(state.data, key, []) do
      [] ->
        {:reply, {:ok, nil}, state}

      list ->
        {value, new_list} = List.pop_at(list, -1)

        new_data =
          if new_list == [],
            do: Map.delete(state.data, key),
            else: Map.put(state.data, key, new_list)

        {:reply, {:ok, value}, %{state | data: new_data}}
    end
  end

  def handle_call({:command, ["LINDEX", key, -1]}, _from, state) do
    result =
      case Map.get(state.data, key, []) do
        [] -> nil
        list -> List.last(list)
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:command, ["KEYS", pattern]}, _from, state) do
    keys =
      state.data
      |> Map.keys()
      |> Enum.filter(&String.match?(&1, ~r/#{String.replace(pattern, "*", ".*")}/))

    {:reply, {:ok, keys}, state}
  end

  # Mock sliding window script
  def handle_call({:eval, script, [key], [window_ms, limit, _now, _request_id]}, _from, state)
      when is_binary(script) do
    # Simple mock: track request count per key
    current_count = Map.get(state.data, "#{key}:count", 0)

    if current_count < limit do
      new_data = Map.put(state.data, "#{key}:count", current_count + 1)
      remaining = limit - current_count - 1
      {:reply, {:ok, [1, remaining]}, %{state | data: new_data}}
    else
      # Mock retry after
      retry_after = div(window_ms, 2)
      {:reply, {:ok, [0, retry_after]}, state}
    end
  end

  # Mock queue enqueue script
  def handle_call({:eval, _script, [queue_key], [max_size, request_data]}, _from, state) do
    current_list = Map.get(state.data, queue_key, [])

    if length(current_list) >= max_size do
      {:reply, {:ok, [0, "queue_full"]}, state}
    else
      new_list = [request_data | current_list]
      new_data = Map.put(state.data, queue_key, new_list)
      {:reply, {:ok, [1, length(new_list)]}, %{state | data: new_data}}
    end
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{data: %{}, scripts: %{}}}
  end

  def handle_call(:debug_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(_, _from, state) do
    {:reply, {:ok, nil}, state}
  end
end
