# test/test_helper.exs
ExUnit.start()

# Realistic Mock Redis that matches the actual Redis API interface
defmodule MockRedis do
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok,
     %{
       # String keys -> values
       strings: %{},
       # List keys -> [values]
       lists: %{},
       # Sorted set keys -> %{member => score}
       zsets: %{},
       # Hash keys -> %{field => value}
       hashes: %{},
       # Key expiration times
       expires: %{}
     }}
  end

  # Public API functions that match Redix interface
  def command(cmd), do: GenServer.call(__MODULE__, {:command, cmd})
  def eval(script, keys, args), do: GenServer.call(__MODULE__, {:eval, script, keys, args})

  # Test utilities
  def reset, do: GenServer.call(__MODULE__, :reset)
  def debug_state, do: GenServer.call(__MODULE__, :debug_state)

  # === STRING COMMANDS ===
  def handle_call({:command, ["GET", key]}, _from, state) do
    value = Map.get(state.strings, key)
    {:reply, {:ok, value}, state}
  end

  def handle_call({:command, ["SET", key, value]}, _from, state) do
    new_strings = Map.put(state.strings, key, value)
    {:reply, {:ok, "OK"}, %{state | strings: new_strings}}
  end

  def handle_call({:command, ["DEL" | keys]}, _from, state) do
    deleted_count =
      keys
      |> Enum.reduce(0, fn key, acc ->
        if has_key?(state, key), do: acc + 1, else: acc
      end)

    new_state =
      keys
      |> Enum.reduce(state, fn key, acc_state ->
        %{
          acc_state
          | strings: Map.delete(acc_state.strings, key),
            lists: Map.delete(acc_state.lists, key),
            zsets: Map.delete(acc_state.zsets, key),
            hashes: Map.delete(acc_state.hashes, key),
            expires: Map.delete(acc_state.expires, key)
        }
      end)

    {:reply, {:ok, deleted_count}, new_state}
  end

  # === LIST COMMANDS ===
  def handle_call({:command, ["LPUSH", key, value]}, _from, state) do
    current_list = Map.get(state.lists, key, [])
    new_list = [value | current_list]
    new_lists = Map.put(state.lists, key, new_list)
    {:reply, {:ok, length(new_list)}, %{state | lists: new_lists}}
  end

  def handle_call({:command, ["RPUSH", key, value]}, _from, state) do
    current_list = Map.get(state.lists, key, [])
    new_list = current_list ++ [value]
    new_lists = Map.put(state.lists, key, new_list)
    {:reply, {:ok, length(new_list)}, %{state | lists: new_lists}}
  end

  def handle_call({:command, ["LPOP", key]}, _from, state) do
    case Map.get(state.lists, key, []) do
      [] ->
        {:reply, {:ok, nil}, state}

      [head | tail] ->
        new_lists =
          if tail == [] do
            Map.delete(state.lists, key)
          else
            Map.put(state.lists, key, tail)
          end

        {:reply, {:ok, head}, %{state | lists: new_lists}}
    end
  end

  def handle_call({:command, ["RPOP", key]}, _from, state) do
    case Map.get(state.lists, key, []) do
      [] ->
        {:reply, {:ok, nil}, state}

      list ->
        {value, new_list} = List.pop_at(list, -1)

        new_lists =
          if new_list == [] do
            Map.delete(state.lists, key)
          else
            Map.put(state.lists, key, new_list)
          end

        {:reply, {:ok, value}, %{state | lists: new_lists}}
    end
  end

  def handle_call({:command, ["LLEN", key]}, _from, state) do
    length = Map.get(state.lists, key, []) |> length()
    {:reply, {:ok, length}, state}
  end

  def handle_call({:command, ["LINDEX", key, index]}, _from, state) do
    list = Map.get(state.lists, key, [])

    result =
      cond do
        index == -1 -> List.last(list)
        index >= 0 and index < length(list) -> Enum.at(list, index)
        true -> nil
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:command, ["LRANGE", key, start_idx, end_idx]}, _from, state) do
    list = Map.get(state.lists, key, [])
    list_length = length(list)

    # Convert negative indices
    start_pos = if start_idx < 0, do: max(0, list_length + start_idx), else: start_idx
    end_pos = if end_idx < 0, do: list_length + end_idx, else: min(end_idx, list_length - 1)

    result =
      if start_pos <= end_pos and start_pos < list_length do
        list
        |> Enum.slice(start_pos..end_pos)
      else
        []
      end

    {:reply, {:ok, result}, state}
  end

  # === SORTED SET COMMANDS ===
  def handle_call({:command, ["ZADD", key, score, member]}, _from, state) do
    score_num = if is_binary(score), do: String.to_float(score), else: score
    zset = Map.get(state.zsets, key, %{})
    new_zset = Map.put(zset, member, score_num)
    new_zsets = Map.put(state.zsets, key, new_zset)

    {:reply, {:ok, 1}, %{state | zsets: new_zsets}}
  end

  def handle_call({:command, ["ZCARD", key]}, _from, state) do
    count = Map.get(state.zsets, key, %{}) |> map_size()
    {:reply, {:ok, count}, state}
  end

  def handle_call({:command, ["ZRANGE", key, start_idx, end_idx | opts]}, _from, state) do
    zset = Map.get(state.zsets, key, %{})

    # Sort by score, then by member lexicographically
    sorted_members =
      zset
      |> Enum.sort_by(fn {member, score} -> {score, member} end)

    # Handle range selection
    selected =
      if start_idx == 0 and end_idx == -1 do
        sorted_members
      else
        list_length = length(sorted_members)
        start_pos = if start_idx < 0, do: max(0, list_length + start_idx), else: start_idx
        end_pos = if end_idx < 0, do: list_length + end_idx, else: min(end_idx, list_length - 1)

        if start_pos <= end_pos and start_pos < list_length do
          Enum.slice(sorted_members, start_pos..end_pos)
        else
          []
        end
      end

    # Return with or without scores
    result =
      if "WITHSCORES" in opts do
        Enum.flat_map(selected, fn {member, score} -> [member, score] end)
      else
        Enum.map(selected, fn {member, _score} -> member end)
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:command, ["ZREMRANGEBYSCORE", key, min_score, max_score]}, _from, state) do
    zset = Map.get(state.zsets, key, %{})

    {min_val, max_val} = parse_score_range(min_score, max_score)

    {removed_members, remaining_zset} =
      Enum.reduce(zset, {[], %{}}, fn {member, score}, {removed, remaining} ->
        if score >= min_val and score <= max_val do
          {[member | removed], remaining}
        else
          {removed, Map.put(remaining, member, score)}
        end
      end)

    removed_count = length(removed_members)

    new_zsets =
      if map_size(remaining_zset) == 0 do
        Map.delete(state.zsets, key)
      else
        Map.put(state.zsets, key, remaining_zset)
      end

    {:reply, {:ok, removed_count}, %{state | zsets: new_zsets}}
  end

  # === UTILITY COMMANDS ===
  def handle_call({:command, ["KEYS", pattern]}, _from, state) do
    all_keys =
      [
        Map.keys(state.strings),
        Map.keys(state.lists),
        Map.keys(state.zsets),
        Map.keys(state.hashes)
      ]
      |> List.flatten()
      |> Enum.uniq()

    # Simple pattern matching for * wildcards
    regex_pattern =
      pattern
      |> String.replace("*", ".*")
      |> String.replace("?", ".")

    matching_keys =
      all_keys
      |> Enum.filter(&String.match?(&1, ~r/^#{regex_pattern}$/))

    {:reply, {:ok, matching_keys}, state}
  end

  def handle_call({:command, ["EXPIRE", key, _seconds]}, _from, state) do
    # Mock implementation - just acknowledge the expiration
    # In a real implementation, this would set an expiration timer
    exists = has_key?(state, key)
    result = if exists, do: 1, else: 0
    {:reply, {:ok, result}, state}
  end

  def handle_call({:command, ["PING"]}, _from, state) do
    {:reply, {:ok, "PONG"}, state}
  end

  # === SCRIPT DETECTION ===

  defp is_rate_limit_script?(script) do
    String.contains?(script, "window_ms") or
      String.contains?(script, "ZREMRANGEBYSCORE") or
      String.contains?(script, "sliding")
  end

  defp is_queue_script?(script) do
    String.contains?(script, "max_size") or
      String.contains?(script, "queue_full") or
      String.contains?(script, "LPUSH")
  end

  defp is_batch_script?(script) do
    String.contains?(script, "batch") or
      String.contains?(script, "#keys")
  end

  defp is_queue_stats_script?(script) do
    (String.contains?(script, "LLEN") and String.contains?(script, "avg_wait_time")) or
      (String.contains?(script, "expired") and String.contains?(script, "total_wait_time"))
  end

  defp is_queue_cleanup_script?(script) do
    (String.contains?(script, "expires_at") and String.contains?(script, "LRANGE")) or
      (String.contains?(script, "cjson.decode") and String.contains?(script, "expires_at"))
  end

  defp is_usage_history_script?(script) do
    (String.contains?(script, "intervals") and String.contains?(script, "buckets")) or
      (String.contains?(script, "interval_size") and String.contains?(script, "ZRANGE"))
  end

  defp is_window_info_script?(script) do
    (String.contains?(script, "oldest_time") and String.contains?(script, "newest_time")) or
      (String.contains?(script, "ZCARD") and String.contains?(script, "ZRANGE"))
  end

  defp is_check_only_script?(script) do
    String.contains?(script, "window_ms") and String.contains?(script, "limit") and
      not String.contains?(script, "ZADD")
  end

  defp is_batch_dequeue_script?(script) do
    (String.contains?(script, "RPOP") and String.contains?(script, "count")) or
      String.contains?(script, "for i = 1, count")
  end

  defp is_cleanup_script?(script) do
    String.contains?(script, "cleaned") or
      String.contains?(script, "TYPE")
  end

  # === SCRIPT HANDLERS ===

  defp handle_rate_limit_script([key], [window_ms, limit, now, request_id], state) do
    # Clean expired entries
    window_start = now - window_ms
    zset = Map.get(state.zsets, key, %{})

    cleaned_zset =
      zset
      |> Enum.reject(fn {_member, score} -> score < window_start end)
      |> Enum.into(%{})

    current_count = map_size(cleaned_zset)

    if current_count < limit do
      # Allow request - add to sorted set
      new_zset = Map.put(cleaned_zset, request_id, now)
      new_zsets = Map.put(state.zsets, key, new_zset)
      remaining = limit - current_count - 1

      {:reply, {:ok, [1, remaining, now]}, %{state | zsets: new_zsets}}
    else
      # Deny request - calculate retry after
      retry_after =
        if map_size(cleaned_zset) > 0 do
          oldest_score = cleaned_zset |> Map.values() |> Enum.min()
          max(0, oldest_score + window_ms - now)
        else
          0
        end

      # Update state with cleaned zset
      new_zsets =
        if map_size(cleaned_zset) == 0 do
          Map.delete(state.zsets, key)
        else
          Map.put(state.zsets, key, cleaned_zset)
        end

      {:reply, {:ok, [0, retry_after, now]}, %{state | zsets: new_zsets}}
    end
  end

  defp handle_queue_script([queue_key], [max_size, request_data | rest], state) do
    current_list = Map.get(state.lists, queue_key, [])

    if length(current_list) >= max_size do
      {:reply, {:ok, [0, "queue_full"]}, state}
    else
      priority = if length(rest) > 0, do: hd(rest), else: 0

      new_list =
        if priority > 0 do
          # High priority: add to front
          [request_data | current_list]
        else
          # Normal priority: add to back
          current_list ++ [request_data]
        end

      new_lists = Map.put(state.lists, queue_key, new_list)
      {:reply, {:ok, [1, length(new_list)]}, %{state | lists: new_lists}}
    end
  end

  defp handle_batch_script(keys, [window_ms, "batch", now | limits], state) do
    results =
      Enum.zip(keys, limits)
      |> Enum.map(fn {key, limit} ->
        zset = Map.get(state.zsets, key, %{})
        window_start = now - window_ms

        # Clean expired entries
        cleaned_zset =
          zset
          |> Enum.reject(fn {_member, score} -> score < window_start end)
          |> Enum.into(%{})

        current_count = map_size(cleaned_zset)

        if current_count < limit do
          [1, limit - current_count]
        else
          retry_after =
            if map_size(cleaned_zset) > 0 do
              oldest_score = cleaned_zset |> Map.values() |> Enum.min()
              max(0, oldest_score + window_ms - now)
            else
              0
            end

          [0, retry_after]
        end
      end)

    {:reply, {:ok, results}, state}
  end

  defp handle_cleanup_script(state) do
    # Mock cleanup - count empty sorted sets that could be cleaned
    empty_zsets =
      state.zsets
      |> Enum.count(fn {_key, zset} -> map_size(zset) == 0 end)

    # Remove empty sorted sets
    new_zsets =
      state.zsets
      |> Enum.reject(fn {_key, zset} -> map_size(zset) == 0 end)
      |> Enum.into(%{})

    {:reply, {:ok, empty_zsets}, %{state | zsets: new_zsets}}
  end

  defp handle_queue_stats_script([queue_key], [now], state) do
    list = Map.get(state.lists, queue_key, [])
    length = length(list)

    if length == 0 do
      {:reply, {:ok, [0, 0, 0, 0, 0]}, state}
    else
      # Mock queue statistics - simulate realistic values
      # Mock: no expired items for simplicity
      expired_count = 0
      # Mock: 5 seconds average wait
      avg_wait_time = 5000
      # Mock: oldest request 10 seconds ago
      oldest_queued = now - 10000
      # Mock: newest request 1 second ago
      newest_queued = now - 1000

      {:reply, {:ok, [length, expired_count, avg_wait_time, oldest_queued, newest_queued]}, state}
    end
  end

  defp handle_queue_cleanup_script([queue_key], [now], state) do
    list = Map.get(state.lists, queue_key, [])

    # Mock: assume all items are valid (not expired) for simplicity
    # In a real implementation, this would parse JSON and check expires_at
    removed_count = 0

    {:reply, {:ok, removed_count}, state}
  end

  defp handle_usage_history_script([key], [window_ms, now, intervals, interval_size], state) do
    # Mock usage history - create realistic buckets
    buckets =
      1..intervals
      |> Enum.map(fn i ->
        # Simulate some usage with randomness
        count = if :rand.uniform() > 0.7, do: :rand.uniform(5), else: 0
        count
      end)

    {:reply, {:ok, buckets}, state}
  end

  defp handle_window_info_script([key], [window_ms, now], state) do
    zset = Map.get(state.zsets, key, %{})
    count = map_size(zset)

    if count == 0 do
      {:reply, {:ok, [0, 0, 0]}, state}
    else
      scores = Map.values(zset)
      oldest_time = Enum.min(scores)
      newest_time = Enum.max(scores)

      {:reply, {:ok, [count, oldest_time, newest_time]}, state}
    end
  end

  defp handle_check_only_script([key], [window_ms, limit, now], state) do
    # Similar to rate limit script but without adding new request
    window_start = now - window_ms
    zset = Map.get(state.zsets, key, %{})

    cleaned_zset =
      zset
      |> Enum.reject(fn {_member, score} -> score < window_start end)
      |> Enum.into(%{})

    current_count = map_size(cleaned_zset)

    if current_count < limit do
      remaining = limit - current_count
      {:reply, {:ok, [1, remaining]}, state}
    else
      retry_after =
        if map_size(cleaned_zset) > 0 do
          oldest_score = cleaned_zset |> Map.values() |> Enum.min()
          max(0, oldest_score + window_ms - now)
        else
          0
        end

      {:reply, {:ok, [0, retry_after]}, state}
    end
  end

  defp handle_batch_dequeue_script([queue_key], [count], state) do
    list = Map.get(state.lists, queue_key, [])

    # Take up to 'count' items from the end (RPOP behavior)
    {items_to_return, remaining_list} =
      if length(list) <= count do
        # Return all items, reverse for RPOP order
        {Enum.reverse(list), []}
      else
        split_point = length(list) - count
        {list_start, list_end} = Enum.split(list, split_point)
        {Enum.reverse(list_end), list_start}
      end

    # Update state
    new_lists =
      if remaining_list == [] do
        Map.delete(state.lists, queue_key)
      else
        Map.put(state.lists, queue_key, remaining_list)
      end

    {:reply, {:ok, items_to_return}, %{state | lists: new_lists}}
  end
end
