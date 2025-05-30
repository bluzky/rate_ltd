defmodule RateLtd.MixProject do
  use Mix.Project

  def project do
    [
      app: :rate_ltd,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RateLtd.Application, []}
    ]
  end

  defp deps do
    [
      {:redix, "~> 1.2"},
      {:poolboy, "~> 1.5"},
      {:jason, "~> 1.4", optional: true},
      {:uuid, "~> 1.1"},
      {:telemetry, "~> 1.2", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    "A distributed rate limiting library for Elixir applications with Redis backend and queueing capabilities."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/your-username/rate_ltd"}
    ]
  end
end
