# RateLtd

A distributed rate limiting library for Elixir applications with Redis backend and queueing capabilities.

## Features

- **Distributed Rate Limiting**: Accurate rate limiting across multiple nodes using Redis
- **Multiple Algorithms**: Sliding window, fixed window, and token bucket algorithms
- **Request Queueing**: Automatic queueing when rate limits are exceeded
- **Background Processing**: Simple queue processor for handling queued requests
- **Priority Support**: Optional priority levels for queue processing
- **Graceful Degradation**: Continues operating when Redis is unavailable
- **Telemetry Integration**: Built-in metrics and observability
- **Flexible Configuration**: Runtime configuration with sensible defaults

## Installation

Add `rate_ltd` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rate_ltd, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Configuration

Configure Redis connection and default settings in your `config/config.exs`:

```elixir
config :rate_ltd, :redis,
  host: "localhost",
  port: 6379,
  database: 0,
  pool_size: 10,
  timeout: 5_000

config :rate_ltd, :defaults,
  rate_limit_window_ms: 60_000,
  queue_timeout_ms: 300_000,
  max_queue_size: 1_000
```

### 2. Basic Usage

```elixir
# Simple rate-limited request (blocks until executed)
case RateLtd.request("external_api", fn ->
  HTTPClient.get("https://api.example.com/data")
end) do
  {:ok, response} -> handle_success(response)
  {:error, reason} -> handle_error(reason)
end

# Check rate limit without executing
case RateLtd.check("external_api") do
  {:allow, remaining} -> make_request()
  {:deny, retry_after_ms} -> Process.sleep(retry_after_ms)
end
```

### 3. Advanced Configuration

```elixir
# Configure specific rate limits and queues
rate_configs = [
  RateLtd.RateLimitConfig.new("external_api", 100, 60_000),
  RateLtd.RateLimitConfig.new("internal_api", 1000, 60_000)
]

queue_configs = [
  RateLtd.QueueConfig.new("external_api:queue", max_size: 500),
  RateLtd.QueueConfig.new("internal_api:queue", max_size: 100)
]

RateLtd.configure(rate_configs, queue_configs)
```

## Usage Examples

### Blocking Mode (Default)

```elixir
# Basic blocking request
{:ok, result} = RateLtd.request("api_key", fn ->
  ThirdPartyAPI.call(data)
end)

# With custom timeout
{:ok, result} = RateLtd.request("api_key", fn ->
  SlowAPI.call(data)
end, %{timeout_ms: 60_000})

# With priority (higher numbers = higher priority)
{:ok, result} = RateLtd.request("api_key", fn ->
  ImportantAPI.call(data)
end, %{priority: 2, timeout_ms: 30_000})
```

### Async Mode

```elixir
case RateLtd.request("api_key", fn -> 
  HTTPClient.get("/data") 
end, %{async: true}) do
  {:ok, response} -> 
    # Executed immediately
    handle_response(response)
    
  {:queued, %{request_id: id, estimated_wait_ms: wait_time}} ->
    # Request was queued
    IO.puts("Request queued, estimated wait: #{wait_time}ms")
    
    # Wait for result
    receive do
      {:rate_ltd_result, ^id, {:ok, result}} -> 
        handle_response(result)
      {:rate_ltd_result, ^id, {:error, reason}} -> 
        handle_error(reason)
      {:rate_ltd_expired, ^id, :timeout} -> 
        handle_timeout()
    after 
      60_000 -> handle_timeout()
    end
    
  {:error, :queue_full} -> 
    handle_queue_full()
end
```

### Error Handling

```elixir
case RateLtd.request("api_key", fn -> 
  risky_operation() 
end) do
  {:ok, result} -> 
    handle_success(result)
    
  {:error, :timeout} -> 
    handle_timeout()
    
  {:error, :queue_full} -> 
    handle_queue_full()
    
  {:error, {:function_error, exception}} -> 
    handle_function_error(exception)
end
```

## Configuration Reference

### Rate Limit Configuration

```elixir
%RateLtd.RateLimitConfig{
  key: "api_name:action",           # Unique identifier
  limit: 20,                        # Requests per window
  window_ms: 60_000,               # Time window in milliseconds
  algorithm: :sliding_window        # :fixed_window | :sliding_window | :token_bucket
}
```

### Queue Configuration

```elixir
%RateLtd.QueueConfig{
  name: "api_name:queue",           # Queue identifier
  max_size: 1000,                   # Maximum queued requests
  request_timeout_ms: 300_000,      # Request TTL (5 minutes)
  enable_priority: false,           # Priority queue support
  overflow_strategy: :reject        # :reject | :drop_oldest
}
```

### Request Options

```elixir
%RateLtd.RequestOptions{
  timeout_ms: 30_000,               # How long to wait total (blocking mode)
  priority: 1,                      # Queue priority (1 = highest)
  async: false,                     # true = return immediately if queued
  max_retries: 3                    # Number of immediate retries before queueing
}
```

## Monitoring and Observability

### Get Status Information

```elixir
status = RateLtd.get_status("api_key")

# Rate limit status
IO.inspect(status.rate_limit.remaining)  # Remaining requests
IO.inspect(status.rate_limit.reset_at)   # When limit resets

# Queue status  
IO.inspect(status.queue.depth)           # Current queue depth
IO.inspect(status.queue.oldest_request_age_ms)  # Age of oldest request

# Processor status
IO.inspect(status.processor.active)      # Is processor running
IO.inspect(status.processor.queues_processed)  # Total queues processed
```

### Telemetry Events

RateLtd emits telemetry events for monitoring:

```elixir
# Rate limiter events
[:rate_ltd, :rate_limiter, :rate_limit_allowed]
[:rate_ltd, :rate_limiter, :rate_limit_denied] 
[:rate_ltd, :rate_limiter, :rate_limit_error]

# Queue manager events
[:rate_ltd, :queue_manager, :request_enqueued]
[:rate_ltd, :queue_manager, :request_dequeued]
[:rate_ltd, :queue_manager, :request_rejected]

# Queue processor events
[:rate_ltd, :queue_processor, :request_executed]
[:rate_ltd, :queue_processor, :processing_completed]
```

### Processor Control

```elixir
# Pause queue processing
RateLtd.QueueProcessor.pause()

# Resume queue processing
RateLtd.QueueProcessor.resume()

# Get processor status
status = RateLtd.QueueProcessor.get_status()
```

## Production Considerations

### Redis Setup

- **Version**: Redis 6.0+ recommended
- **Memory**: Configure appropriate memory limits for your queue sizes
- **Persistence**: Enable RDB or AOF for queue persistence
- **Clustering**: Redis Cluster supported for high availability

### Performance Tuning

```elixir
# High-throughput configuration
config :rate_ltd, :redis,
  pool_size: 20,
  timeout: 1_000

config :rate_ltd, :processor,
  polling_interval_ms: 500,
  batch_size: 200
```

### Memory Management

- Set reasonable queue sizes to prevent memory issues
- Use request timeouts to clean up old requests
- Monitor Redis memory usage
- Enable automatic cleanup in processor

### Error Handling

- RateLtd fails open when Redis is unavailable
- Implement circuit breakers for external APIs
- Monitor queue depths and processing latency
- Set up alerts for Redis connection issues

## Testing

Run the test suite:

```bash
mix test
```

For integration tests with Redis:

```bash
# Start Redis
redis-server

# Run tests
mix test
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Run the test suite
6. Submit a pull request

## License

MIT License. See LICENSE for details.

## Changelog

### Version 0.1.0

- Initial release
- Basic rate limiting with Redis backend
- Request queueing with configurable options
- Background queue processor
- Telemetry integration
- Comprehensive test suite
