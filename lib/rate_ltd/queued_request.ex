defmodule RateLtd.QueuedRequest do
  @moduledoc """
  Represents a queued request placeholder.
  The actual function is kept by the caller process.
  """

  @type t :: %__MODULE__{
    id: String.t(),
    queue_name: String.t(),
    rate_limit_key: String.t(),
    priority: pos_integer(),
    queued_at: DateTime.t(),
    expires_at: DateTime.t(),
    caller_pid: pid() | nil,
    caller_ref: reference() | nil
  }

  defstruct id: nil,
            queue_name: nil,
            rate_limit_key: nil,
            priority: 1,
            queued_at: nil,
            expires_at: nil,
            caller_pid: nil,
            caller_ref: nil

  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(queue_name, rate_limit_key, opts \\ []) do
    now = DateTime.utc_now()
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)

    %__MODULE__{
      id: UUID.uuid4(),
      queue_name: queue_name,
      rate_limit_key: rate_limit_key,
      priority: Keyword.get(opts, :priority, 1),
      queued_at: now,
      expires_at: expires_at,
      caller_pid: Keyword.get(opts, :caller_pid),
      caller_ref: Keyword.get(opts, :caller_ref)
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = request) do
    data = %{
      id: request.id,
      queue_name: request.queue_name,
      rate_limit_key: request.rate_limit_key,
      priority: request.priority,
      queued_at: DateTime.to_iso8601(request.queued_at),
      expires_at: DateTime.to_iso8601(request.expires_at),
      caller_pid: if(request.caller_pid, do: :erlang.term_to_binary(request.caller_pid) |> Base.encode64()),
      caller_ref: if(request.caller_ref, do: :erlang.term_to_binary(request.caller_ref) |> Base.encode64())
    }
    
    Jason.encode!(data)
  end

  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    with {:ok, data} <- Jason.decode(binary),
         {:ok, queued_at, _offset} <- DateTime.from_iso8601(data["queued_at"]),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(data["expires_at"]) do
      
      request = %__MODULE__{
        id: data["id"],
        queue_name: data["queue_name"],
        rate_limit_key: data["rate_limit_key"],
        priority: data["priority"],
        queued_at: queued_at,
        expires_at: expires_at,
        caller_pid: decode_pid(data["caller_pid"]),
        caller_ref: decode_ref(data["caller_ref"])
      }
      
      {:ok, request}
    else
      error -> {:error, error}
    end
  end

  defp decode_pid(nil), do: nil
  defp decode_pid(encoded) do
    try do
      encoded
      |> Base.decode64!()
      |> :erlang.binary_to_term()
    rescue
      _ -> nil
    end
  end

  defp decode_ref(nil), do: nil
  defp decode_ref(encoded) do
    try do
      encoded
      |> Base.decode64!()
      |> :erlang.binary_to_term()
    rescue
      _ -> nil
    end
  end
end
