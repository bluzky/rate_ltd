defmodule RateLtd.LuaScripts do
  @moduledoc """
  Lua scripts for atomic Redis operations.
  """

  @sliding_window_script """
  local key = KEYS[1]
  local window_ms = tonumber(ARGV[1])
  local limit = tonumber(ARGV[2])
  local now = tonumber(ARGV[3])
  local request_id = ARGV[4]

  -- Clean up expired entries
  local window_start = now - window_ms
  redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

  -- Get current count
  local current_count = redis.call('ZCARD', key)

  if current_count < limit then
    -- Add the new request
    redis.call('ZADD', key, now, request_id)
    redis.call('EXPIRE', key, math.ceil(window_ms / 1000))
    
    local remaining = limit - current_count - 1
    local reset_at = now + window_ms
    
    return {1, current_count + 1, remaining, reset_at}
  else
    -- Get the oldest entry to calculate retry_after
    local oldest_entries = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = 0
    
    if #oldest_entries > 0 then
      local oldest_time = tonumber(oldest_entries[2])
      retry_after = math.max(0, (oldest_time + window_ms) - now)
    end
    
    return {0, current_count, 0, retry_after}
  end
  """

  @fixed_window_script """
  local key = KEYS[1]
  local window_ms = tonumber(ARGV[1])
  local limit = tonumber(ARGV[2])
  local now = tonumber(ARGV[3])

  -- Calculate window start
  local window_start = math.floor(now / window_ms) * window_ms
  local window_key = key .. ':' .. window_start

  -- Get current count
  local current_count = tonumber(redis.call('GET', window_key) or '0')

  if current_count < limit then
    -- Increment and set expiry
    local new_count = redis.call('INCR', window_key)
    redis.call('EXPIRE', window_key, math.ceil(window_ms / 1000))
    
    local remaining = limit - new_count
    local reset_at = window_start + window_ms
    
    return {1, new_count, remaining, reset_at}
  else
    local reset_at = window_start + window_ms
    local retry_after = reset_at - now
    
    return {0, current_count, 0, retry_after}
  end
  """

  @enqueue_script """
  local queue_key = KEYS[1]
  local priority_queue_key = KEYS[2]
  local max_size = tonumber(ARGV[1])
  local request_data = ARGV[2]
  local expires_at = tonumber(ARGV[3])
  local priority = tonumber(ARGV[4])
  local overflow_strategy = ARGV[5]

  -- Get current queue size
  local current_size = redis.call('LLEN', queue_key)
  
  if priority > 1 and priority_queue_key then
    current_size = current_size + redis.call('LLEN', priority_queue_key)
  end

  if current_size >= max_size then
    if overflow_strategy == 'drop_oldest' then
      -- Remove oldest item
      redis.call('RPOP', queue_key)
    else
      -- Reject new request
      return {0, 'queue_full'}
    end
  end

  -- Add to appropriate queue
  local target_queue = queue_key
  if priority > 1 and priority_queue_key then
    target_queue = priority_queue_key
  end

  redis.call('LPUSH', target_queue, request_data)
  
  -- Set TTL for the request (Redis will handle cleanup)
  local ttl_seconds = math.ceil(expires_at / 1000)
  redis.call('EXPIRE', target_queue, ttl_seconds)

  return {1, current_size + 1}
  """

  @dequeue_script """
  local priority_queue_key = KEYS[1]
  local regular_queue_key = KEYS[2]

  -- Try priority queue first
  if priority_queue_key then
    local item = redis.call('RPOP', priority_queue_key)
    if item then
      return {item, 'priority'}
    end
  end

  -- Try regular queue
  local item = redis.call('RPOP', regular_queue_key)
  if item then
    return {item, 'regular'}
  end

  return {nil, nil}
  """

  @cleanup_expired_script """
  local queue_key = KEYS[1]
  local now = tonumber(ARGV[1])
  local cleaned = 0

  -- Get all items
  local items = redis.call('LRANGE', queue_key, 0, -1)
  
  -- Clear the queue
  redis.call('DEL', queue_key)
  
  -- Re-add non-expired items
  for i = #items, 1, -1 do
    local item_data = cjson.decode(items[i])
    local expires_at = tonumber(item_data.expires_at)
    
    if expires_at > now then
      redis.call('LPUSH', queue_key, items[i])
    else
      cleaned = cleaned + 1
    end
  end

  return cleaned
  """

  def sliding_window_script, do: @sliding_window_script
  def fixed_window_script, do: @fixed_window_script
  def enqueue_script, do: @enqueue_script
  def dequeue_script, do: @dequeue_script
  def cleanup_expired_script, do: @cleanup_expired_script
end
