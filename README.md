# RateLtd

A distributed rate limiting library for Elixir applications with Redis backend and queueing capabilities.

## Features

- **Distributed Rate Limiting**: Uses Redis as a backend for coordinated rate limiting across multiple application instances
- **Sliding Window Algorithm**: Implements precise rate limiting using Redis sorted sets
- **Queue Management**: Automatic queueing of rate-limited requests with configurable timeouts
- **Fail-Open Strategy**: Gracefully handles Redis connectivity issues by allowing requests through
- **Connection Pooling**: Efficient Redis connection management using Poolboy
- **Flexible Configuration**: Per-key configuration with sensible defaults

## Installation

Add `rate_ltd` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rate_ltd, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure RateLtd in your `config/config.exs`:

```elixir
config :rate_ltd,
  # Redis connection settings
  redis: [
    url: "redis://localhost:1234/0",
    pool_size: 5
  ],
  # Default rate limiting settings
  defaults: [
    limit: 100,           # requests per window
    window_ms: 60_000,    # 1 minute window
    max_queue_size: 1000  # maximum queued requests
  ],
  # Per-key configurations
  configs: %{
    "api_calls" => %{limit: 1000, window_ms: 60_000, max_queue_size: 500},
    "user_login" => {5, 300_000},  # 5 requests per 5 minutes (tuple format)
    "heavy_operation" => %{limit: 10, window_ms: 3600_000, max_queue_size: 50}
  }
```

## Usage

### Basic Rate Limiting

```elixir
# Simple rate check
case RateLtd.check("api_user_123") do
  {:allow, remaining} ->
    IO.puts("Request allowed, #{remaining} requests remaining")
  {:deny, retry_after_ms} ->
    IO.puts("Rate limited, retry after #{retry_after_ms}ms")
end
```

### Execute Function with Rate Limiting

```elixir
# Execute a function with automatic rate limiting and queueing
result = RateLtd.request("api_user_123", fn ->
  # Your rate-limited operation here
  HTTPoison.get("https://api.example.com/data")
end)

case result do
  {:ok, response} ->
    IO.puts("Function executed successfully")
  {:error, :timeout} ->
    IO.puts("Request timed out in queue")
  {:error, :queue_full} ->
    IO.puts("Queue is full, request rejected")
  {:error, {:function_error, error}} ->
    IO.puts("Function raised an error: #{inspect(error)}")
end
```

### Advanced Options

```elixir
# Custom timeout and retry settings
RateLtd.request("heavy_task", fn ->
  perform_heavy_computation()
end, timeout_ms: 60_000, max_retries: 5)
```

### Reset Rate Limits

```elixir
# Reset rate limit for a specific key
RateLtd.reset("api_user_123")
```

## How It Works

### Sliding Window Algorithm

RateLtd uses a sliding window algorithm implemented with Redis sorted sets:

1. **Window Management**: Each request is stored with a timestamp in a Redis sorted set
2. **Cleanup**: Expired entries outside the current window are automatically removed
3. **Rate Checking**: Current request count is compared against the configured limit
4. **Precise Timing**: Calculates exact retry-after times based on the oldest request

### Queue Processing

When rate limits are exceeded:

1. **Queueing**: Requests are queued in Redis lists with expiration times
2. **Background Processing**: A GenServer processes queues every 2 seconds
3. **Process Signaling**: Waiting processes are notified when their turn arrives
4. **Cleanup**: Expired requests and dead processes are automatically cleaned up

### Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │───▶│    RateLtd      │───▶│     Redis       │
│                 │    │                 │    │                 │
│  RateLtd.request│    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│  RateLtd.check  │    │ │   Limiter   │ │    │ │ Sorted Sets │ │
│                 │    │ └─────────────┘ │    │ │    Lists    │ │
│                 │    │ ┌─────────────┐ │    │ └─────────────┘ │
│                 │    │ │    Queue    │ │    │                 │
│                 │    │ └─────────────┘ │    │                 │
│                 │    │ ┌─────────────┐ │    │                 │
│                 │    │ │ Processor   │ │    │                 │
│                 │    │ └─────────────┘ │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## API Reference

### RateLtd.request/2,3

Executes a function with rate limiting and automatic queueing.

```elixir
@spec request(String.t(), function()) :: {:ok, term()} | {:error, term()}
@spec request(String.t(), function(), keyword()) :: {:ok, term()} | {:error, term()}
```

**Parameters:**
- `key` - Rate limiting key (string)
- `function` - Function to execute when rate limit allows
- `opts` - Options (optional)
  - `:timeout_ms` - Queue timeout in milliseconds (default: 30,000)
  - `:max_retries` - Maximum retry attempts for short delays (default: 3)

**Returns:**
- `{:ok, result}` - Function executed successfully
- `{:error, :timeout}` - Request timed out in queue
- `{:error, :queue_full}` - Queue exceeded maximum size
- `{:error, {:function_error, error}}` - Function raised an exception

### RateLtd.check/1

Checks if a request would be allowed without executing anything.

```elixir
@spec check(String.t()) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
```

**Parameters:**
- `key` - Rate limiting key (string)

**Returns:**
- `{:allow, remaining}` - Request allowed, remaining requests in window
- `{:deny, retry_after_ms}` - Request denied, retry after specified milliseconds

### RateLtd.reset/1

Resets the rate limit for a specific key.

```elixir
@spec reset(String.t()) :: :ok
```

**Parameters:**
- `key` - Rate limiting key to reset (string)

## Configuration Examples

### API Rate Limiting

```elixir
config :rate_ltd,
  defaults: [limit: 1000, window_ms: 60_000],
  configs: %{
    "api_v1" => %{limit: 5000, window_ms: 60_000, max_queue_size: 1000},
    "api_v2" => %{limit: 10000, window_ms: 60_000, max_queue_size: 2000}
  }
```

### User-Based Limits

```elixir
# In your application
user_key = "user:#{user_id}"
RateLtd.request(user_key, fn ->
  UserService.expensive_operation(user_id)
end)
```

### Service-to-Service Communication

```elixir
service_key = "service:payment_processor"
RateLtd.request(service_key, fn ->
  PaymentAPI.process_payment(payment_params)
end, timeout_ms: 10_000)
```

## Error Handling

RateLtd implements a fail-open strategy for Redis connectivity issues:

- **Redis Unavailable**: Requests are allowed through with maximum remaining count
- **Invalid Responses**: Treated as successful rate limit checks
- **Network Timeouts**: Default to allowing requests

## Performance Considerations

- **Redis Operations**: Most operations use atomic Lua scripts for consistency
- **Connection Pooling**: Configurable pool size (default: 5 connections)
- **Queue Processing**: Runs every 2 seconds with minimal Redis queries
- **Memory Usage**: Automatic cleanup of expired entries and dead processes

## Testing

RateLtd includes support for testing by allowing Redis module injection:

```elixir
# In test configuration
config :rate_ltd, redis_module: MockRedis
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`mix test`)
4. Run Credo (`mix credo`)
5. Run Dialyzer (`mix dialyzer`)
6. Commit your changes (`git commit -am 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
