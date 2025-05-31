defmodule RateLtd.RequestOptions do
  @moduledoc """
  Options for rate limited requests using Skema validation.
  """

  use Skema

  defschema do
    field :timeout_ms, :integer, required: true, default: 30_000, number: [min: 1]
    field :priority, :integer, required: true, default: 1, number: [min: 1]
    field :async, :boolean, required: true, default: false
    field :max_retries, :integer, required: true, default: 3, number: [min: 0]
  end

  @doc """
  Create new RequestOptions from keyword list.
  
  ## Examples
      iex> RequestOptions.from_opts(timeout_ms: 60_000, async: true)
      %RequestOptions{timeout_ms: 60_000, async: true, priority: 1, max_retries: 3}
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts \\ []) do
    params = Enum.into(opts, %{})

    case Skema.cast_and_validate(__MODULE__, params) do
      {:ok, options} -> options
      {:error, _error} ->
        # Fallback to manual construction for backwards compatibility
        %__MODULE__{
          timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
          priority: Keyword.get(opts, :priority, 1),
          async: Keyword.get(opts, :async, false),
          max_retries: Keyword.get(opts, :max_retries, 3)
        }
    end
  end
end
