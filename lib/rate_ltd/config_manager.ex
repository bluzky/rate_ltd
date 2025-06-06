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

  @spec get_config(String.t()) :: config()
  def get_config("bucket:" <> rest) do
    [group, api_key] = String.split(rest, ":", parts: 2)
    get_grouped_config(group, api_key)
  end

  def get_config("simple:" <> key) do
    get_simple_config(key)
  end

  @spec get_grouped_config(String.t(), String.t()) :: config()
  defp get_grouped_config(group, api_key) do
    defaults = get_defaults()
    group_configs = get_group_configs()
    api_key_configs = get_api_key_configs()

    # Priority: api_key specific > group specific > defaults
    config =
      case Map.get(api_key_configs, "#{group}:#{api_key}") do
        nil ->
          case Map.get(group_configs, group) do
            nil -> build_default_config(defaults)
            group_config -> normalize_config(group_config, defaults)
          end

        api_key_config ->
          normalize_config(api_key_config, defaults)
      end

    Map.put(config, :bucket_type, :grouped)
  end

  @spec get_simple_config(String.t()) :: config()
  defp get_simple_config(key) do
    defaults = get_defaults()
    simple_configs = get_simple_configs()

    config =
      case Map.get(simple_configs, key) do
        nil -> build_default_config(defaults)
        config -> normalize_config(config, defaults)
      end

    Map.put(config, :bucket_type, :simple)
  end

  @spec build_default_config(keyword()) :: config()
  defp build_default_config(defaults) do
    %{
      limit: Keyword.get(defaults, :limit, 100),
      window_ms: Keyword.get(defaults, :window_ms, 60_000),
      max_queue_size: Keyword.get(defaults, :max_queue_size, 1000)
    }
  end

  @spec normalize_config(map() | {integer(), integer()}, keyword()) :: config()
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

  @spec validate_config(config()) :: :ok | {:error, String.t()}
  def validate_config(config) do
    cond do
      not is_integer(config.limit) or config.limit < 0 ->
        {:error, "limit must be a non-negative integer"}

      not is_integer(config.window_ms) or config.window_ms <= 0 ->
        {:error, "window_ms must be a positive integer"}

      not is_integer(config.max_queue_size) or config.max_queue_size < 0 ->
        {:error, "max_queue_size must be a non-negative integer"}

      true ->
        :ok
    end
  end

  @spec get_config_source(String.t()) :: {:api_key | :group | :default, String.t()}
  def get_config_source("bucket:" <> rest) do
    [group, api_key] = String.split(rest, ":", parts: 2)
    api_key_configs = get_api_key_configs()
    group_configs = get_group_configs()

    cond do
      Map.has_key?(api_key_configs, "#{group}:#{api_key}") ->
        {:api_key, "#{group}:#{api_key}"}

      Map.has_key?(group_configs, group) ->
        {:group, group}

      true ->
        {:default, "defaults"}
    end
  end

  def get_config_source("simple:" <> key) do
    simple_configs = get_simple_configs()

    if Map.has_key?(simple_configs, key) do
      {:simple, key}
    else
      {:default, "defaults"}
    end
  end

  # Private helper functions for getting configuration values

  defp get_defaults do
    Application.get_env(:rate_ltd, :defaults, [])
  end

  defp get_group_configs do
    Application.get_env(:rate_ltd, :group_configs, %{})
  end

  defp get_api_key_configs do
    Application.get_env(:rate_ltd, :api_key_configs, %{})
  end

  defp get_simple_configs do
    Application.get_env(:rate_ltd, :configs, %{})
  end
end
