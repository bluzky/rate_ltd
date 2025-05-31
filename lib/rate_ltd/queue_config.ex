defmodule RateLtd.QueueConfig do
  @moduledoc """
  Configuration for queue management using Skema validation.
  """

  use Skema

  @type overflow_strategy :: :reject | :drop_oldest

  defschema do
    field :name, :string, required: true, string: [min_length: 1]
    field :max_size, :integer, required: true, default: 1000, number: [min: 1]
    field :request_timeout_ms, :integer, required: true, default: 300_000, number: [min: 1]
    field :enable_priority, :boolean, required: true, default: false
    field :overflow_strategy, :atom, required: true, default: :reject, enum: [:reject, :drop_oldest]
  end

  @doc """
  Create new QueueConfig with name and options.
  
  ## Examples
      iex> QueueConfig.from_name_and_opts("test_queue", max_size: 500, enable_priority: true)
      %QueueConfig{name: "test_queue", max_size: 500, enable_priority: true, ...}
  """
  @spec from_name_and_opts(String.t(), keyword()) :: t()
  def from_name_and_opts(name, opts \\ []) do
    params = 
      opts
      |> Keyword.put(:name, name)
      |> Enum.into(%{})

    case Skema.cast_and_validate(__MODULE__, params) do
      {:ok, config} -> config
      {:error, _error} -> 
        # Fallback to manual construction for backwards compatibility
        %__MODULE__{
          name: name,
          max_size: Keyword.get(opts, :max_size, 1000),
          request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 300_000),
          enable_priority: Keyword.get(opts, :enable_priority, false),
          overflow_strategy: Keyword.get(opts, :overflow_strategy, :reject)
        }
    end
  end
end
