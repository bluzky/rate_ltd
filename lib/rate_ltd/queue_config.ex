defmodule RateLtd.QueueConfig do
  @moduledoc """
  Configuration for queue management.
  """

  @type overflow_strategy :: :reject | :drop_oldest

  @type t :: %__MODULE__{
    name: String.t(),
    max_size: pos_integer(),
    request_timeout_ms: pos_integer(),
    enable_priority: boolean(),
    overflow_strategy: overflow_strategy()
  }

  defstruct name: nil,
            max_size: 1000,
            request_timeout_ms: 300_000,
            enable_priority: false,
            overflow_strategy: :reject

  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      max_size: Keyword.get(opts, :max_size, 1000),
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 300_000),
      enable_priority: Keyword.get(opts, :enable_priority, false),
      overflow_strategy: Keyword.get(opts, :overflow_strategy, :reject)
    }
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = config) do
    with :ok <- validate_name(config.name),
         :ok <- validate_max_size(config.max_size),
         :ok <- validate_request_timeout_ms(config.request_timeout_ms),
         :ok <- validate_overflow_strategy(config.overflow_strategy) do
      {:ok, config}
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_max_size(max_size) when is_integer(max_size) and max_size > 0, do: :ok
  defp validate_max_size(_), do: {:error, :invalid_max_size}

  defp validate_request_timeout_ms(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_request_timeout_ms(_), do: {:error, :invalid_request_timeout_ms}

  defp validate_overflow_strategy(strategy) when strategy in [:reject, :drop_oldest], do: :ok
  defp validate_overflow_strategy(_), do: {:error, :invalid_overflow_strategy}
end
