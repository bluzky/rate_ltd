defmodule RateLtd.RequestOptions do
  @moduledoc """
  Options for rate limited requests.
  """

  @type t :: %__MODULE__{
    timeout_ms: pos_integer(),
    priority: pos_integer(),
    async: boolean(),
    max_retries: non_neg_integer()
  }

  defstruct timeout_ms: 30_000,
            priority: 1,
            async: false,
            max_retries: 3

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      priority: Keyword.get(opts, :priority, 1),
      async: Keyword.get(opts, :async, false),
      max_retries: Keyword.get(opts, :max_retries, 3)
    }
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = options) do
    with :ok <- validate_timeout_ms(options.timeout_ms),
         :ok <- validate_priority(options.priority),
         :ok <- validate_max_retries(options.max_retries) do
      {:ok, options}
    end
  end

  defp validate_timeout_ms(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout_ms(_), do: {:error, :invalid_timeout_ms}

  defp validate_priority(priority) when is_integer(priority) and priority > 0, do: :ok
  defp validate_priority(_), do: {:error, :invalid_priority}

  defp validate_max_retries(retries) when is_integer(retries) and retries >= 0, do: :ok
  defp validate_max_retries(_), do: {:error, :invalid_max_retries}
end
