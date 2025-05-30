defmodule RateLtd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:rate_ltd)
    
    children = [
      {RateLtd.RedisManager, redis_config(config)},
      {RateLtd.ConfigManager, []},
      {RateLtd.QueueProcessor, processor_config(config)}
    ]

    opts = [strategy: :one_for_one, name: RateLtd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp redis_config(config) do
    Keyword.get(config, :redis, [
      host: "localhost",
      port: 6379,
      database: 0,
      pool_size: 10,
      timeout: 5_000
    ])
  end

  defp processor_config(config) do
    Keyword.get(config, :processor, [
      polling_interval_ms: 1_000,
      batch_size: 100,
      enable_cleanup: true
    ])
  end
end
