# lib/rate_ltd/redis.ex
defmodule RateLtd.Redis do
  @moduledoc """
  Simple Redis wrapper with connection pooling.
  """
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def command(cmd) do
    :poolboy.transaction(__MODULE__.Pool, fn conn ->
      Redix.command(conn, cmd)
    end)
  end

  def eval(script, keys, args) do
    :poolboy.transaction(__MODULE__.Pool, fn conn ->
      Redix.command(conn, ["EVAL", script, length(keys)] ++ keys ++ args)
    end)
  end

  def init(config) do
    config = Keyword.merge(default_config(), config)

    pool_config = [
      name: {:local, __MODULE__.Pool},
      worker_module: Redix,
      size: config[:pool_size],
      max_overflow: 0
    ]

    worker_config = [
      host: config[:host],
      port: config[:port],
      database: config[:database]
    ]

    case :poolboy.start_link(pool_config, worker_config) do
      {:ok, _pool} -> {:ok, config}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp default_config do
    [
      host: "localhost",
      port: 6379,
      database: 0,
      pool_size: 5
    ]
  end
end
