defmodule RateLtd.RateLimitConfig do
  @moduledoc """
  Configuration for rate limiting rules using Skema validation.
  """

  use Skema

  @type algorithm :: :sliding_window | :fixed_window | :token_bucket

  defschema do
    field :key, :string, required: true, string: [min_length: 1]
    field :limit, :integer, required: true, default: 100, number: [min: 1]
    field :window_ms, :integer, required: true, default: 60_000, number: [min: 1]
    field :algorithm, :atom, required: true, default: :sliding_window, enum: [:sliding_window, :fixed_window, :token_bucket]
  end

  # Function header with default arguments
  @spec new(String.t(), pos_integer(), pos_integer(), algorithm()) :: t()
  def new(key, limit, window_ms, algorithm \\ :sliding_window)

  def new(key, limit, window_ms, algorithm) do
    params = %{
      key: key,
      limit: limit,
      window_ms: window_ms,
      algorithm: algorithm
    }

    case Skema.cast_and_validate(__MODULE__, params) do
      {:ok, config} -> config
      {:error, _error} ->
        # Fallback for backwards compatibility
        %__MODULE__{
          key: key,
          limit: limit,
          window_ms: window_ms,
          algorithm: algorithm
        }
    end
  end
end
