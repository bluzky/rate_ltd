# test/rate_ltd/config_manager_test.exs
defmodule RateLtd.ConfigManagerTest do
  use ExUnit.Case, async: false

  setup do
    # Store original config
    original_defaults = Application.get_env(:rate_ltd, :defaults)
    original_group_configs = Application.get_env(:rate_ltd, :group_configs)
    original_api_key_configs = Application.get_env(:rate_ltd, :api_key_configs)
    original_configs = Application.get_env(:rate_ltd, :configs)

    # Set test configuration
    Application.put_env(:rate_ltd, :defaults,
      limit: 100,
      window_ms: 60_000,
      max_queue_size: 1000
    )

    Application.put_env(:rate_ltd, :group_configs, %{
      "payment_api" => %{limit: 1000, window_ms: 60_000, max_queue_size: 500},
      "search_api" => %{limit: 5000, window_ms: 60_000, max_queue_size: 2000},
      # Test tuple format
      "tuple_config" => {200, 30_000}
    })

    Application.put_env(:rate_ltd, :api_key_configs, %{
      "payment_api:premium_merchant" => %{limit: 5000, window_ms: 60_000},
      "search_api:enterprise_client" => %{limit: 50000, window_ms: 60_000, max_queue_size: 5000}
    })

    Application.put_env(:rate_ltd, :configs, %{
      "legacy_key" => %{limit: 200, window_ms: 90_000},
      "tuple_legacy" => {150, 45_000}
    })

    on_exit(fn ->
      # Restore original config
      if original_defaults, do: Application.put_env(:rate_ltd, :defaults, original_defaults)

      if original_group_configs,
        do: Application.put_env(:rate_ltd, :group_configs, original_group_configs)

      if original_api_key_configs,
        do: Application.put_env(:rate_ltd, :api_key_configs, original_api_key_configs)

      if original_configs, do: Application.put_env(:rate_ltd, :configs, original_configs)
    end)

    :ok
  end

  describe "get_config/1 for grouped buckets" do
    test "returns default config when no specific config exists" do
      config = RateLtd.ConfigManager.get_config("bucket:unknown_group:unknown_key")

      assert config.limit == 100
      assert config.window_ms == 60_000
      assert config.max_queue_size == 1000
      assert config.bucket_type == :grouped
    end

    test "returns group config when group exists" do
      config = RateLtd.ConfigManager.get_config("bucket:payment_api:merchant_123")

      assert config.limit == 1000
      assert config.window_ms == 60_000
      assert config.max_queue_size == 500
      assert config.bucket_type == :grouped
    end

    test "returns API key specific config when available" do
      config = RateLtd.ConfigManager.get_config("bucket:payment_api:premium_merchant")

      assert config.limit == 5000
      assert config.window_ms == 60_000
      # Uses default since not specified
      assert config.max_queue_size == 1000
      assert config.bucket_type == :grouped
    end

    test "handles tuple format group config" do
      config = RateLtd.ConfigManager.get_config("bucket:tuple_config:test_key")

      assert config.limit == 200
      assert config.window_ms == 30_000
      # Uses default
      assert config.max_queue_size == 1000
      assert config.bucket_type == :grouped
    end

    test "API key config overrides group config" do
      # First check group config
      group_config = RateLtd.ConfigManager.get_config("bucket:search_api:regular_client")
      assert group_config.limit == 5000

      # Then check API key specific config (should override)
      api_key_config = RateLtd.ConfigManager.get_config("bucket:search_api:enterprise_client")
      assert api_key_config.limit == 50000
      # Specific override
      assert api_key_config.max_queue_size == 5000
    end
  end

  describe "get_config/1 for simple keys" do
    test "returns default config when no specific config exists" do
      config = RateLtd.ConfigManager.get_config("simple:unknown_key")

      assert config.limit == 100
      assert config.window_ms == 60_000
      assert config.max_queue_size == 1000
      assert config.bucket_type == :simple
    end

    test "returns specific config when available" do
      config = RateLtd.ConfigManager.get_config("simple:legacy_key")

      assert config.limit == 200
      assert config.window_ms == 90_000
      # Uses default
      assert config.max_queue_size == 1000
      assert config.bucket_type == :simple
    end

    test "handles tuple format simple config" do
      config = RateLtd.ConfigManager.get_config("simple:tuple_legacy")

      assert config.limit == 150
      assert config.window_ms == 45_000
      # Uses default
      assert config.max_queue_size == 1000
      assert config.bucket_type == :simple
    end
  end

  describe "validate_config/1" do
    test "validates correct config" do
      valid_config = %{
        limit: 100,
        window_ms: 60_000,
        max_queue_size: 1000
      }

      assert :ok = RateLtd.ConfigManager.validate_config(valid_config)
    end

    test "rejects negative limit" do
      invalid_config = %{
        limit: -10,
        window_ms: 60_000,
        max_queue_size: 1000
      }

      assert {:error, "limit must be a non-negative integer"} =
               RateLtd.ConfigManager.validate_config(invalid_config)
    end

    test "rejects zero or negative window_ms" do
      invalid_config = %{
        limit: 100,
        window_ms: 0,
        max_queue_size: 1000
      }

      assert {:error, "window_ms must be a positive integer"} =
               RateLtd.ConfigManager.validate_config(invalid_config)

      invalid_config2 = %{
        limit: 100,
        window_ms: -1000,
        max_queue_size: 1000
      }

      assert {:error, "window_ms must be a positive integer"} =
               RateLtd.ConfigManager.validate_config(invalid_config2)
    end

    test "rejects negative max_queue_size" do
      invalid_config = %{
        limit: 100,
        window_ms: 60_000,
        max_queue_size: -5
      }

      assert {:error, "max_queue_size must be a non-negative integer"} =
               RateLtd.ConfigManager.validate_config(invalid_config)
    end

    test "allows zero limit" do
      zero_limit_config = %{
        limit: 0,
        window_ms: 60_000,
        max_queue_size: 1000
      }

      assert :ok = RateLtd.ConfigManager.validate_config(zero_limit_config)
    end

    test "allows zero max_queue_size" do
      zero_queue_config = %{
        limit: 100,
        window_ms: 60_000,
        max_queue_size: 0
      }

      assert :ok = RateLtd.ConfigManager.validate_config(zero_queue_config)
    end
  end

  describe "get_config_source/1" do
    test "identifies API key specific source" do
      {source, key} =
        RateLtd.ConfigManager.get_config_source("bucket:payment_api:premium_merchant")

      assert source == :api_key
      assert key == "payment_api:premium_merchant"
    end

    test "identifies group source" do
      {source, key} =
        RateLtd.ConfigManager.get_config_source("bucket:payment_api:regular_merchant")

      assert source == :group
      assert key == "payment_api"
    end

    test "identifies default source for grouped buckets" do
      {source, key} = RateLtd.ConfigManager.get_config_source("bucket:unknown_group:unknown_key")
      assert source == :default
      assert key == "defaults"
    end

    test "identifies simple key source" do
      {source, key} = RateLtd.ConfigManager.get_config_source("simple:legacy_key")
      assert source == :simple
      assert key == "legacy_key"
    end

    test "identifies default source for simple keys" do
      {source, key} = RateLtd.ConfigManager.get_config_source("simple:unknown_simple_key")
      assert source == :default
      assert key == "defaults"
    end
  end

  describe "configuration priority" do
    test "API key config has highest priority" do
      # Set up a scenario where all three levels have different values
      Application.put_env(:rate_ltd, :defaults, limit: 100)

      Application.put_env(:rate_ltd, :group_configs, %{
        "test_priority" => %{limit: 500}
      })

      Application.put_env(:rate_ltd, :api_key_configs, %{
        "test_priority:special_key" => %{limit: 2000}
      })

      # API key config should win
      config = RateLtd.ConfigManager.get_config("bucket:test_priority:special_key")
      assert config.limit == 2000

      # Group config should be used for other keys in the same group
      config2 = RateLtd.ConfigManager.get_config("bucket:test_priority:regular_key")
      assert config2.limit == 500

      # Default should be used for unknown groups
      config3 = RateLtd.ConfigManager.get_config("bucket:unknown_group:any_key")
      assert config3.limit == 100
    end

    test "group config overrides defaults" do
      config = RateLtd.ConfigManager.get_config("bucket:search_api:any_key")

      # Should use group config, not defaults
      # From group config
      assert config.limit == 5000
      # From group config
      assert config.window_ms == 60_000
      # From group config
      assert config.max_queue_size == 2000
    end

    test "defaults are used when no other config exists" do
      config = RateLtd.ConfigManager.get_config("bucket:nonexistent_group:any_key")

      # Should use defaults
      assert config.limit == 100
      assert config.window_ms == 60_000
      assert config.max_queue_size == 1000
    end
  end

  describe "configuration merging" do
    test "partial API key config merges with group config" do
      # API key config only specifies limit, should inherit other values from group
      config = RateLtd.ConfigManager.get_config("bucket:payment_api:premium_merchant")

      # From API key config
      assert config.limit == 5000
      # From group config fallback
      assert config.window_ms == 60_000
      # From defaults (not in group config)
      assert config.max_queue_size == 1000
    end

    test "partial group config merges with defaults" do
      # Set up a group config that only partially overrides defaults
      Application.put_env(:rate_ltd, :group_configs, %{
        # Only override limit
        "partial_group" => %{limit: 300}
      })

      config = RateLtd.ConfigManager.get_config("bucket:partial_group:test_key")

      # From group config
      assert config.limit == 300
      # From defaults
      assert config.window_ms == 60_000
      # From defaults
      assert config.max_queue_size == 1000
    end
  end

  describe "edge cases" do
    test "handles missing configuration gracefully" do
      # Temporarily remove all config
      Application.delete_env(:rate_ltd, :defaults)
      Application.delete_env(:rate_ltd, :group_configs)
      Application.delete_env(:rate_ltd, :api_key_configs)
      Application.delete_env(:rate_ltd, :configs)

      config = RateLtd.ConfigManager.get_config("bucket:any_group:any_key")

      # Should use hardcoded defaults
      assert config.limit == 100
      assert config.window_ms == 60_000
      assert config.max_queue_size == 1000
    end

    test "handles bucket key with extra colons" do
      config = RateLtd.ConfigManager.get_config("bucket:group:key:with:extra:colons")

      # Should parse group as "group" and api_key as "key:with:extra:colons"
      assert is_map(config)
      assert config.bucket_type == :grouped
    end
  end

  describe "configuration format compatibility" do
    test "supports map format" do
      Application.put_env(:rate_ltd, :group_configs, %{
        "map_format" => %{
          limit: 123,
          window_ms: 45_000,
          max_queue_size: 456
        }
      })

      config = RateLtd.ConfigManager.get_config("bucket:map_format:test")

      assert config.limit == 123
      assert config.window_ms == 45_000
      assert config.max_queue_size == 456
    end

    test "supports tuple format" do
      Application.put_env(:rate_ltd, :group_configs, %{
        "tuple_format" => {789, 90_000}
      })

      config = RateLtd.ConfigManager.get_config("bucket:tuple_format:test")

      assert config.limit == 789
      assert config.window_ms == 90_000
      # Uses default
      assert config.max_queue_size == 1000
    end

    test "map format overrides tuple format completely" do
      # When map format is used, it should completely replace defaults
      Application.put_env(:rate_ltd, :group_configs, %{
        "complete_override" => %{
          limit: 999,
          window_ms: 12_000,
          max_queue_size: 111
        }
      })

      config = RateLtd.ConfigManager.get_config("bucket:complete_override:test")

      assert config.limit == 999
      assert config.window_ms == 12_000
      assert config.max_queue_size == 111
    end
  end
end
