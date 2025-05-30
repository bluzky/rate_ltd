import Config

# Redis connection configuration
config :rate_ltd, :redis,
  host: "localhost",
  port: 6379,
  database: 0,
  pool_size: 10,
  timeout: 5_000

# Queue processor configuration  
config :rate_ltd, :processor,
  polling_interval_ms: 1_000,
  batch_size: 100,
  enable_cleanup: true

# Default configurations
config :rate_ltd, :defaults,
  rate_limit_window_ms: 60_000,
  queue_timeout_ms: 300_000,
  max_queue_size: 1_000

# Example rate limit configurations
# config :rate_ltd, :rate_limits, [
#   {"api:external", limit: 100, window_ms: 60_000, algorithm: :sliding_window},
#   {"api:internal", limit: 1000, window_ms: 60_000, algorithm: :fixed_window}
# ]

# Example queue configurations
# config :rate_ltd, :queues, [
#   {"api:external:queue", max_size: 500, request_timeout_ms: 300_000},
#   {"api:internal:queue", max_size: 100, request_timeout_ms: 60_000}
# ]

# Import environment specific config files
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
