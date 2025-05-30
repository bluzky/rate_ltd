defmodule RateLtd.RateLimitConfig do
  @moduledoc """
  Configuration for rate limiting rules.
  """

  @type algorithm :: :sliding_window | :fixed_window | :token_bucket

  @type t :: %__MODULE__{
    key: String.t(),
    limit: pos_integer(),
    window_ms: pos_integer(),
    algorithm: algorithm()
  }

  defstruct key: nil,
            limit: 100,
            window_ms: 60_000,
            algorithm: :sliding_window

  @spec new(String.t(), pos_integer(), pos_integer(), algorithm()) :: t()
  def new(key, limit, window_ms, algorithm \\ :sliding_window) do
    %__MODULE__{
      key: key,
      limit: limit,
      window_ms: window_ms,
      algorithm: algorithm
    }
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = config) do
    with :ok <- validate_key(config.key),
         :ok <- validate_limit(config.limit),
         :ok <- validate_window_ms(config.window_ms),
         :ok <- validate_algorithm(config.algorithm) do
      {:ok, config}
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_limit(_), do: {:error, :invalid_limit}

  defp validate_window_ms(window_ms) when is_integer(window_ms) and window_ms > 0, do: :ok
  defp validate_window_ms(_), do: {:error, :invalid_window_ms}

  defp validate_algorithm(algorithm) when algorithm in [:sliding_window, :fixed_window, :token_bucket], do: :ok
  defp validate_algorithm(_), do: {:error, :invalid_algorithm}
end
