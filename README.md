# RateLtd

A high-performance, distributed rate limiting library for Elixir applications with local queuing and Redis-backed sliding window algorithm.

## Installation

Add `rate_ltd` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rate_ltd, "~> 1.0"},
  ]
end
```

## Basic Usage

### Simple Rate Limiting

```elixir
# Basic rate limiting with string keys
result = RateLtd.request("user_123", fn ->
  # Your API call or business logic
  ExternalAPI.fetch_data()
end)

case result do
  {:ok, data} ->
    # Request was allowed and executed
    IO.puts("Success: #{data}")
  {:error, :timeout} ->
    # Request was queued but timed out
    IO.puts("Request timed out in queue")
  {:error, :queue_full} ->
    # Local queue is full
    IO.puts("Too many pending requests")
end
```

### Grouped Rate Limiting

```elixir
# Different rate limits per service using {group, api_key} tuples
RateLtd.request({"payment_api", "merchant_123"}, fn ->
  PaymentProcessor.charge(amount, card)
end)

RateLtd.request({"search_api", "merchant_123"}, fn ->
  SearchService.query(terms)
end)
```

### Check Rate Limits

```elixir
# Check current rate limit status without consuming quota
case RateLtd.check({"payment_api", "merchant_123"}) do
  {:allow, remaining} ->
    IO.puts("#{remaining} requests remaining")
  {:deny, retry_after_ms} ->
    IO.puts("Rate limited, retry after #{retry_after_ms}ms")
end
```

### Monitor Usage

```elixir
# Get detailed bucket statistics
stats = RateLtd.get_bucket_stats({"payment_api", "merchant_123"})
# => %{
#   bucket_key: "bucket:payment_api:merchant_123",
#   used: 150,
#   remaining: 350,
#   limit: 500,
#   window_ms: 60000,
#   bucket_type: :grouped_bucket
# }

# List all active buckets
active_buckets = RateLtd.list_active_buckets()

# Get group-level summary
summary = RateLtd.get_group_summary("payment_api")
```

## Configuration

Configure in your `config/config.exs`:

```elixir
config :rate_ltd,
  # Global defaults
  defaults: [
    limit: 100,
    window_ms: 60_000,
    max_queue_size: 1000
  ],

  # Group-level configurations
  group_configs: %{
    "payment_api" => %{
      limit: 1000,
      window_ms: 60_000,
      max_queue_size: 500
    },
    "search_api" => %{
      limit: 5000,
      window_ms: 60_000,
      max_queue_size: 2000
    }
  },

  # API key specific configurations (highest priority)
  api_key_configs: %{
    "payment_api:premium_merchant" => %{
      limit: 5000,
      window_ms: 60_000
    },
    "search_api:enterprise_client" => %{
      limit: 50000,
      window_ms: 60_000
    }
  },

  # Simple key configurations (backward compatibility)
  configs: %{
    "legacy_api_key" => %{
      limit: 200,
      window_ms: 60_000
    }
  },

  # Redis configuration
  redis: [
    host: "localhost",
    port: 6379,
    database: 0,
    pool_size: 5
  ],

  # Queue processing interval (milliseconds)
  queue_check_interval: 1000
```

### Configuration Priority

Configuration is resolved with the following priority (highest to lowest):

1. **API Key Specific**: `api_key_configs["group:api_key"]`
2. **Group Level**: `group_configs["group"]`
3. **Global Defaults**: `defaults`

## Features

### ✨ Core Features

- **Sliding Window Algorithm**: Precise rate limiting using Redis sorted sets
- **Grouped Buckets**: Service-specific rate limits with `{group, api_key}` tuples
- **Local Queuing**: ETS-based local queue with Redis metrics tracking
- **Parallel Processing**: Process queued requests in parallel by rate limit key
- **Hierarchical Configuration**: API key > group > global configuration resolution

### 🚀 Performance & Reliability

- **Distributed Architecture**: Each node maintains local queue with shared Redis state
- **Fail-Safe Operation**: Graceful degradation when Redis is unavailable
- **Memory Efficient**: Local ETS storage with automatic cleanup
- **Low Latency**: Fast local checks with Redis-backed precision

### ⚙️ Advanced Options

- **Custom Timeouts**: Configure per-request timeout for queued requests
- **Retry Logic**: Automatic retry with configurable attempts
- **Queue Size Limits**: Prevent memory issues with configurable queue limits
- **Window Flexibility**: Support for different time windows per service

### 🔧 Development & Testing

- **Non-consuming Checks**: `RateLtd.check/1` reads state without consuming quota
- **Manual Reset**: `RateLtd.reset/1` for testing and emergency situations
- **Comprehensive Test Suite**: Full test coverage with async test support
- **Easy Integration**: Drop-in replacement for existing rate limiting solutions

## Architecture

RateLtd uses a hybrid architecture combining local and distributed components:

- **Local ETS Queue**: Fast, in-memory queue per node
- **Redis Backend**: Shared rate limiting state and sliding window storage
- **Queue Processor**: Background process for executing queued requests
- **Configuration Manager**: Dynamic configuration resolution
- **Bucket Manager**: Statistics collection and monitoring

This design provides the performance of local processing with the accuracy of distributed rate limiting.
