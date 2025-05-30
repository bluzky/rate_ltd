import Config

# Test configuration - use different Redis database
config :rate_ltd, :redis,
  host: "localhost",
  port: 6379,
  database: 1,  # Different database for tests
  pool_size: 5,
  timeout: 5_000

# Faster processing for tests
config :rate_ltd, :processor,
  polling_interval_ms: 100,
  batch_size: 10,
  enable_cleanup: true

# Smaller defaults for testing
config :rate_ltd, :defaults,
  rate_limit_window_ms: 1_000,  # 1 second windows for faster tests
  queue_timeout_ms: 10_000,     # 10 second timeouts
  max_queue_size: 100

# Reduce log noise in tests
config :logger, level: :warning
