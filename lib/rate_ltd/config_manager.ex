# lib/rate_ltd/config_manager.ex
defmodule RateLtd.ConfigManager do
  @moduledoc """
  Manages configuration for different bucket types and groups.

  Handles configuration resolution with the following priority:
  1. API key specific configuration (highest)
  2. Group level configuration
  3. Global defaults (lowest)

  ## Configuration Structure

      config :rate_ltd,
        defaults: [limit: 100, window_ms: 60_000, max_queue_size: 1000],

        # Group-level configurations
        group_configs: %{
          "payment_api" => %{limit: 1000, window_ms: 60_000, max_queue_size: 500},
          "search_api" => %{limit: 5000, window_ms: 60_000, max_queue_size: 2000}
        },

        # Specific API key configurations (overrides group config)
        api_key_configs: %{
          "payment_api:premium_merchant_123" => %{limit: 5000, window_ms: 60_000},
          "search_api:enterprise_client_456" => %{limit: 50000, window_ms: 60_000}
        },

        # Simple key configurations (for backward compatibility)
        configs: %{
          "legacy_api_key" => %{limit: 200, window_ms: 60_000}
        }
  """

  @type config :: %{
          limit: non_neg_integer(),
          window_ms: non_neg_integer(),
          max_queue_size: non_neg_integer(),
          bucket_type: :grouped | :simple
        }

  @doc """
  Retrieves configuration for a given rate limit key.

  Handles both grouped and simple bucket configurations with automatic
  type detection based on key format.

  ## Parameters

    * `key` - The rate limit key in one of these formats:
      - `"bucket:group:api_key"` - For grouped buckets
      - `"simple:key"` - For simple buckets

  ## Returns

  Returns a config map with the following fields:
    * `:limit` - Maximum number of requests allowed in the window
    * `:window_ms` - Time window in milliseconds
    * `:max_queue_size` - Maximum number of requests that can be queued
    * `:bucket_type` - Either `:grouped` or `:simple`

  ## Configuration Resolution Priority

  For grouped buckets (`bucket:group:api_key`):
  1. API key specific config (`api_key_configs["group:api_key"]`)
  2. Group level config (`group_configs["group"]`)
  3. Global defaults

  For simple buckets (`simple:key`):
  1. Key specific config (`configs["key"]`)
  2. Global defaults

  ## Examples

      # Grouped bucket configuration
      iex> RateLtd.ConfigManager.get_config("bucket:payment_api:merchant_123")
      %{
        limit: 1000,
        window_ms: 60_000,
        max_queue_size: 500,
        bucket_type: :grouped
      }

      # Simple bucket configuration
      iex> RateLtd.ConfigManager.get_config("simple:legacy_key")
      %{
        limit: 200,
        window_ms: 60_000,
        max_queue_size: 1000,
        bucket_type: :simple
      }

      # Fallback to defaults for unknown keys
      iex> RateLtd.ConfigManager.get_config("simple:unknown_key")
      %{
        limit: 100,
        window_ms: 60_000,
        max_queue_size: 1000,
        bucket_type: :simple
      }
  """
  @spec get_config(String.t()) :: config()
  def get_config("bucket:" <> rest) do
    [group, api_key] = String.split(rest, ":", parts: 2)
    get_grouped_config(group, api_key)
  end

  def get_config("simple:" <> key) do
    get_simple_config(key)
  end

  # Private functions

  @doc false
  # Complex configuration merging for grouped buckets with three-tier priority system.
  # Merges configurations in priority order: API key specific > group specific > defaults
  defp get_grouped_config(group, api_key) do
    defaults = Application.get_env(:rate_ltd, :defaults, [])
    group_configs = Application.get_env(:rate_ltd, :group_configs, %{})
    api_key_configs = Application.get_env(:rate_ltd, :api_key_configs, %{})

    # Priority: api_key specific > group specific > defaults
    api_key_config = Map.get(api_key_configs, "#{group}:#{api_key}") || %{}
    group_config = Map.get(group_configs, group) || %{}

    config =
      group_config
      |> Map.merge(api_key_config)
      |> normalize_config(defaults)

    Map.put(config, :bucket_type, :grouped)
  end

  @doc false
  # Retrieves configuration for simple (non-grouped) buckets
  defp get_simple_config(key) do
    defaults = Application.get_env(:rate_ltd, :defaults, [])
    simple_configs = Application.get_env(:rate_ltd, :configs, %{})

    config =
      case Map.get(simple_configs, key) do
        nil -> build_default_config(defaults)
        config -> normalize_config(config, defaults)
      end

    Map.put(config, :bucket_type, :simple)
  end

  @doc false
  # Builds default configuration map from keyword list defaults
  defp build_default_config(defaults) do
    %{
      limit: Keyword.get(defaults, :limit, 100),
      window_ms: Keyword.get(defaults, :window_ms, 60_000),
      max_queue_size: Keyword.get(defaults, :max_queue_size, 1000)
    }
  end

  @doc false
  # Normalizes configuration handling multiple input formats.
  # Supports both map format and legacy tuple format {limit, window_ms}
  defp normalize_config(config, defaults) when is_map(config) do
    defaults_map = build_default_config(defaults)
    Map.merge(defaults_map, config)
  end

  defp normalize_config({limit, window_ms}, defaults) do
    %{
      limit: limit,
      window_ms: window_ms,
      max_queue_size: Keyword.get(defaults, :max_queue_size, 1000)
    }
  end
end
