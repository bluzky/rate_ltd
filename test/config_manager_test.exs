defmodule RateLtd.ConfigManagerTest do
  use ExUnit.Case
  alias RateLtd.{ConfigManager, RateLimitConfig, QueueConfig}
  import RateLtd.TestHelpers

  setup do
    Application.ensure_all_started(:rate_ltd)
    # Start a fresh ConfigManager for each test
    if Process.whereis(ConfigManager) do
      GenServer.stop(ConfigManager)
      wait_for_processing(50)
    end
    
    {:ok, _pid} = ConfigManager.start_link([])
    :ok
  end

  describe "configure/2" do
    test "successfully configures rate limits and queues" do
      rate_configs = [
        create_test_rate_config("api:test", 100, 60_000),
        create_test_rate_config("api:external", 50, 30_000)
      ]
      
      queue_configs = [
        create_test_queue_config("api:test:queue", max_size: 500),
        create_test_queue_config("api:external:queue", max_size: 200)
      ]
      
      assert :ok = ConfigManager.configure(rate_configs, queue_configs)
      
      # Verify configurations are stored
      assert {:ok, config} = ConfigManager.get_rate_limit_config("api:test")
      assert config.limit == 100
      assert config.window_ms == 60_000
      
      assert {:ok, queue_config} = ConfigManager.get_queue_config("api:test:queue")
      assert queue_config.max_size == 500
    end

    test "rejects invalid configurations" do
      invalid_rate_configs = [
        %RateLimitConfig{key: nil, limit: 100, window_ms: 60_000}  # nil key
      ]
      
      assert {:error, _reason} = ConfigManager.configure(invalid_rate_configs, [])
    end

    test "replaces existing configurations" do
      # Set initial config
      initial_configs = [create_test_rate_config("api:test", 50, 30_000)]
      ConfigManager.configure(initial_configs, [])
      
      # Replace with new config
      new_configs = [create_test_rate_config("api:test", 100, 60_000)]
      assert :ok = ConfigManager.configure(new_configs, [])
      
      # Verify new config is active
      assert {:ok, config} = ConfigManager.get_rate_limit_config("api:test")
      assert config.limit == 100
      assert config.window_ms == 60_000
    end
  end

  describe "rate limit config management" do
    test "add_rate_limit_config/1 adds new configuration" do
      config = create_test_rate_config("new:api", 200, 120_000)
      
      assert :ok = ConfigManager.add_rate_limit_config(config)
      
      assert {:ok, retrieved} = ConfigManager.get_rate_limit_config("new:api")
      assert retrieved.key == "new:api"
      assert retrieved.limit == 200
    end

    test "add_rate_limit_config/1 rejects invalid configuration" do
      invalid_config = %RateLimitConfig{key: "", limit: -1, window_ms: 60_000}
      
      assert {:error, _reason} = ConfigManager.add_rate_limit_config(invalid_config)
    end

    test "get_rate_limit_config/1 returns not_found for missing config" do
      assert {:error, :not_found} = ConfigManager.get_rate_limit_config("missing:key")
    end

    test "list_rate_limit_configs/0 returns all configurations" do
      config1 = create_test_rate_config("api:one", 100, 60_000)
      config2 = create_test_rate_config("api:two", 200, 120_000)
      
      ConfigManager.add_rate_limit_config(config1)
      ConfigManager.add_rate_limit_config(config2)
      
      configs = ConfigManager.list_rate_limit_configs()
      
      assert length(configs) == 2
      assert Enum.any?(configs, & &1.key == "api:one")
      assert Enum.any?(configs, & &1.key == "api:two")
    end

    test "remove_rate_limit_config/1 removes configuration" do
      config = create_test_rate_config("removable:api", 100, 60_000)
      ConfigManager.add_rate_limit_config(config)
      
      assert {:ok, _} = ConfigManager.get_rate_limit_config("removable:api")
      
      assert :ok = ConfigManager.remove_rate_limit_config("removable:api")
      
      assert {:error, :not_found} = ConfigManager.get_rate_limit_config("removable:api")
    end
  end

  describe "queue config management" do
    test "add_queue_config/1 adds new configuration" do
      config = create_test_queue_config("new:queue", max_size: 300, request_timeout_ms: 180_000)
      
      assert :ok = ConfigManager.add_queue_config(config)
      
      assert {:ok, retrieved} = ConfigManager.get_queue_config("new:queue")
      assert retrieved.name == "new:queue"
      assert retrieved.max_size == 300
      assert retrieved.request_timeout_ms == 180_000
    end

    test "add_queue_config/1 rejects invalid configuration" do
      invalid_config = %QueueConfig{name: "", max_size: -1}
      
      assert {:error, _reason} = ConfigManager.add_queue_config(invalid_config)
    end

    test "get_queue_config/1 returns not_found for missing config" do
      assert {:error, :not_found} = ConfigManager.get_queue_config("missing:queue")
    end

    test "list_queue_configs/0 returns all configurations" do
      config1 = create_test_queue_config("queue:one", max_size: 100)
      config2 = create_test_queue_config("queue:two", max_size: 200)
      
      ConfigManager.add_queue_config(config1)
      ConfigManager.add_queue_config(config2)
      
      configs = ConfigManager.list_queue_configs()
      
      assert length(configs) == 2
      assert Enum.any?(configs, & &1.name == "queue:one")
      assert Enum.any?(configs, & &1.name == "queue:two")
    end

    test "remove_queue_config/1 removes configuration" do
      config = create_test_queue_config("removable:queue")
      ConfigManager.add_queue_config(config)
      
      assert {:ok, _} = ConfigManager.get_queue_config("removable:queue")
      
      assert :ok = ConfigManager.remove_queue_config("removable:queue")
      
      assert {:error, :not_found} = ConfigManager.get_queue_config("removable:queue")
    end
  end

  describe "initial configuration loading" do
    test "loads configurations from application environment" do
      # Stop current ConfigManager
      GenServer.stop(ConfigManager)
      
      # Set application environment
      Application.put_env(:rate_ltd, :rate_limits, [
        {"env:api", limit: 150, window_ms: 90_000}
      ])
      
      Application.put_env(:rate_ltd, :queues, [
        {"env:queue", max_size: 250}
      ])
      
      # Start ConfigManager again
      {:ok, _pid} = ConfigManager.start_link([])
      wait_for_processing(50)
      
      # Verify configs were loaded
      assert {:ok, rate_config} = ConfigManager.get_rate_limit_config("env:api")
      assert rate_config.limit == 150
      assert rate_config.window_ms == 90_000
      
      assert {:ok, queue_config} = ConfigManager.get_queue_config("env:queue")
      assert queue_config.max_size == 250
      
      # Cleanup
      Application.delete_env(:rate_ltd, :rate_limits)
      Application.delete_env(:rate_ltd, :queues)
    end

    test "handles invalid environment configurations gracefully" do
      # Stop current ConfigManager
      GenServer.stop(ConfigManager)
      
      # Set invalid application environment
      Application.put_env(:rate_ltd, :rate_limits, [
        {"invalid:api", limit: -1, window_ms: 60_000}  # Invalid limit
      ])
      
      # Should start successfully despite invalid config
      assert {:ok, _pid} = ConfigManager.start_link([])
      
      # Should not have loaded the invalid config
      assert {:error, :not_found} = ConfigManager.get_rate_limit_config("invalid:api")
      
      # Cleanup
      Application.delete_env(:rate_ltd, :rate_limits)
    end
  end

  describe "configuration formats" do
    test "handles tuple format for rate limits" do
      rate_configs = [
        {"tuple:api", limit: 75, window_ms: 45_000, algorithm: :fixed_window}
      ]
      
      assert :ok = ConfigManager.configure(rate_configs, [])
      
      assert {:ok, config} = ConfigManager.get_rate_limit_config("tuple:api")
      assert config.limit == 75
      assert config.window_ms == 45_000
      assert config.algorithm == :fixed_window
    end

    test "handles map format for rate limits" do
      rate_configs = [
        %{key: "map:api", limit: 125, window_ms: 75_000}
      ]
      
      assert :ok = ConfigManager.configure(rate_configs, [])
      
      assert {:ok, config} = ConfigManager.get_rate_limit_config("map:api")
      assert config.limit == 125
      assert config.window_ms == 75_000
    end

    test "handles tuple format for queues" do
      queue_configs = [
        {"tuple:queue", max_size: 150, request_timeout_ms: 240_000}
      ]
      
      assert :ok = ConfigManager.configure([], queue_configs)
      
      assert {:ok, config} = ConfigManager.get_queue_config("tuple:queue")
      assert config.max_size == 150
      assert config.request_timeout_ms == 240_000
    end

    test "handles map format for queues" do
      queue_configs = [
        %{name: "map:queue", max_size: 175}
      ]
      
      assert :ok = ConfigManager.configure([], queue_configs)
      
      assert {:ok, config} = ConfigManager.get_queue_config("map:queue")
      assert config.max_size == 175
    end
  end
end
