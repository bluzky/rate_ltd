defmodule RateLtd.RateLimitConfigTest do
  use ExUnit.Case
  alias RateLtd.RateLimitConfig

  describe "new/4" do
    test "creates a valid rate limit config" do
      config = RateLimitConfig.new("test:api", 100, 60_000, :sliding_window)
      
      assert config.key == "test:api"
      assert config.limit == 100
      assert config.window_ms == 60_000
      assert config.algorithm == :sliding_window
    end

    test "uses default algorithm when not specified" do
      config = RateLimitConfig.new("test:api", 100, 60_000)
      
      assert config.algorithm == :sliding_window
    end
  end

  describe "validate/1" do
    test "validates correct configuration" do
      config = RateLimitConfig.new("test:api", 100, 60_000)
      
      assert {:ok, ^config} = RateLimitConfig.validate(config)
    end

    test "rejects invalid key" do
      config = %RateLimitConfig{key: "", limit: 100, window_ms: 60_000}
      
      assert {:error, :invalid_key} = RateLimitConfig.validate(config)
    end

    test "rejects invalid limit" do
      config = %RateLimitConfig{key: "test", limit: 0, window_ms: 60_000}
      
      assert {:error, :invalid_limit} = RateLimitConfig.validate(config)
    end

    test "rejects invalid window_ms" do
      config = %RateLimitConfig{key: "test", limit: 100, window_ms: -1}
      
      assert {:error, :invalid_window_ms} = RateLimitConfig.validate(config)
    end

    test "rejects invalid algorithm" do
      config = %RateLimitConfig{key: "test", limit: 100, window_ms: 60_000, algorithm: :invalid}
      
      assert {:error, :invalid_algorithm} = RateLimitConfig.validate(config)
    end
  end
end
