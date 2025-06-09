defmodule RateLtd.Application do
  use Application

  def start(_type, _args) do
    redis_config = Application.get_env(:rate_ltd, :redis, [])

    # Initialize local queue ETS table
    RateLtd.LocalQueue.init()

    children = [
      {RateLtd.Redis, redis_config},
      {RateLtd.QueueProcessor, []}
    ]

    opts = [strategy: :one_for_one, name: RateLtd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
