import Config

# Development configuration
config :rate_ltd, :redis,
  host: "localhost",
  port: 6379,
  database: 0,
  pool_size: 5,
  timeout: 5_000

# Development processor settings
config :rate_ltd, :processor,
  polling_interval_ms: 1_000,
  batch_size: 50,
  enable_cleanup: true

# Development defaults
config :rate_ltd, :defaults,
  rate_limit_window_ms: 60_000,
  queue_timeout_ms: 300_000,
  max_queue_size: 1_000

# More verbose logging in development
config :logger, level: :debug
