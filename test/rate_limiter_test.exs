defmodule RateLtd.RateLimiterTest do
  use ExUnit.Case
  alias RateLtd.{RateLimiter, RateLimitConfig}
  import RateLtd.TestHelpers

  setup do
    Application.ensure_all_started(:rate_ltd)
    clear_redis()
    :ok
  end

  describe "check_rate/2" do
    test "allows requests within limit" do
      config = create_test_rate_config("test:basic", 3, 1000)
      
      assert {:allow, 2} = RateLimiter.check_rate("test:basic", config)
      assert {:allow, 1} = RateLimiter.check_rate("test:basic", config)
      assert {:allow, 0} = RateLimiter.check_rate("test:basic", config)
    end

    test "denies requests exceeding limit" do
      config = create_test_rate_config("test:exceed", 2, 1000)
      
      assert {:allow, 1} = RateLimiter.check_rate("test:exceed", config)
      assert {:allow, 0} = RateLimiter.check_rate("test:exceed", config)
      assert {:deny, _retry_after} = RateLimiter.check_rate("test:exceed", config)
    end

    test "sliding window allows requests after time passes" do
      config = create_test_rate_config("test:sliding", 2, 500)
      
      # Use up the limit
      assert {:allow, 1} = RateLimiter.check_rate("test:sliding", config)
      assert {:allow, 0} = RateLimiter.check_rate("test:sliding", config)
      assert {:deny, _} = RateLimiter.check_rate("test:sliding", config)
      
      # Wait for window to slide
      Process.sleep(600)
      
      # Should be allowed again
      assert {:allow, _} = RateLimiter.check_rate("test:sliding", config)
    end

    test "handles different keys independently" do
      config1 = create_test_rate_config("test:key1", 1, 1000)
      config2 = create_test_rate_config("test:key2", 1, 1000)
      
      assert {:allow, 0} = RateLimiter.check_rate("test:key1", config1)
      assert {:allow, 0} = RateLimiter.check_rate("test:key2", config2)
      
      assert {:deny, _} = RateLimiter.check_rate("test:key1", config1)
      assert {:deny, _} = RateLimiter.check_rate("test:key2", config2)
    end
  end

  describe "get_status/2" do
    test "returns accurate status information" do
      config = create_test_rate_config("test:status", 5, 1000)
      
      # Make some requests
      RateLimiter.check_rate("test:status", config)
      RateLimiter.check_rate("test:status", config)
      
      status = RateLimiter.get_status("test:status", config)
      
      assert status.count == 2
      assert status.remaining == 3
      assert %DateTime{} = status.reset_at
    end

    test "returns zero status for unused key" do
      config = create_test_rate_config("test:unused", 10, 1000)
      
      status = RateLimiter.get_status("test:unused", config)
      
      assert status.count == 0
      assert status.remaining == 10
    end
  end

  describe "reset/1" do
    test "resets rate limit for key" do
      config = create_test_rate_config("test:reset", 1, 1000)
      
      # Use up the limit
      assert {:allow, 0} = RateLimiter.check_rate("test:reset", config)
      assert {:deny, _} = RateLimiter.check_rate("test:reset", config)
      
      # Reset the limit
      assert :ok = RateLimiter.reset("test:reset")
      
      # Should be allowed again
      assert {:allow, 0} = RateLimiter.check_rate("test:reset", config)
    end
  end

  describe "different algorithms" do
    test "fixed window algorithm" do
      config = %RateLimitConfig{
        key: "test:fixed",
        limit: 2,
        window_ms: 1000,
        algorithm: :fixed_window
      }
      
      assert {:allow, 1} = RateLimiter.check_rate("test:fixed", config)
      assert {:allow, 0} = RateLimiter.check_rate("test:fixed", config)
      assert {:deny, _} = RateLimiter.check_rate("test:fixed", config)
    end
  end
end
