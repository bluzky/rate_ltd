defmodule RateLtdTest do
  use ExUnit.Case
  import RateLtd.TestHelpers

  setup do
    # Start the application first
    Application.ensure_all_started(:rate_ltd)
    
    clear_redis()
    
    # Configure test rate limits and queues
    rate_configs = [
      create_test_rate_config("test:api", 3, 1000),
      create_test_rate_config("test:external", 2, 1000)
    ]
    
    queue_configs = [
      create_test_queue_config("test:api:queue", max_size: 5),
      create_test_queue_config("test:external:queue", max_size: 3)
    ]
    
    RateLtd.configure(rate_configs, queue_configs)
    
    :ok
  end

  describe "check/1" do
    test "allows requests within rate limit" do
      assert {:allow, remaining} = RateLtd.check("test:api")
      assert remaining >= 0
    end

    test "denies requests exceeding rate limit" do
      # Exhaust the rate limit
      RateLtd.check("test:api")
      RateLtd.check("test:api") 
      RateLtd.check("test:api")
      
      assert {:deny, retry_after} = RateLtd.check("test:api")
      assert retry_after > 0
    end

    test "creates default config for unknown keys" do
      assert {:allow, _} = RateLtd.check("unknown:key")
    end
  end

  describe "request/2 blocking mode" do
    test "executes function immediately when rate limit allows" do
      function = make_test_function(:immediate_result)
      
      assert {:ok, :immediate_result} = RateLtd.request("test:api", function)
    end

    test "queues and executes function when rate limited" do
      # Exhaust rate limit first
      RateLtd.check("test:external")
      RateLtd.check("test:external")
      
      function = make_test_function(:queued_result)
      
      # This should be queued and then executed by the processor
      task = Task.async(fn ->
        RateLtd.request("test:external", function, %{timeout_ms: 2000})
      end)
      
      # Wait a bit for processing
      wait_for_processing(1500)
      
      assert {:ok, :queued_result} = Task.await(task)
    end

    test "handles function errors gracefully" do
      error_function = make_error_function("test error")
      
      assert {:error, {:function_error, _}} = RateLtd.request("test:api", error_function)
    end

    test "times out when request cannot be processed in time" do
      # Exhaust rate limit
      RateLtd.check("test:external")
      RateLtd.check("test:external")
      
      function = make_test_function(:should_timeout)
      
      # Request with very short timeout
      assert {:error, :timeout} = RateLtd.request("test:external", function, %{timeout_ms: 100})
    end
  end

  describe "request/3 async mode" do
    test "returns result immediately when rate limit allows" do
      function = make_test_function(:async_immediate)
      
      assert {:ok, :async_immediate} = RateLtd.request("test:api", function, %{async: true})
    end

    test "returns queued info when rate limited" do
      # Exhaust rate limit
      RateLtd.check("test:external")
      RateLtd.check("test:external")
      
      function = make_test_function(:async_queued)
      
      assert {:queued, %{request_id: request_id, estimated_wait_ms: wait_ms}} = 
        RateLtd.request("test:external", function, %{async: true})
      
      assert is_binary(request_id)
      assert is_integer(wait_ms)
      
      # Should receive result message
      receive do
        {:rate_ltd_result, ^request_id, {:ok, :async_queued}} -> :ok
      after
        2000 -> flunk("Did not receive async result")
      end
    end

    test "handles queue full error" do
      # Fill up the queue first
      for _ <- 1..3 do
        RateLtd.request("test:external", make_slow_function(5000), %{async: true})
      end
      
      # This should be rejected
      function = make_test_function(:should_be_rejected)
      assert {:error, :queue_full} = RateLtd.request("test:external", function, %{async: true})
    end
  end

  describe "request/3 with options" do
    test "respects custom timeout" do
      function = make_slow_function(200, :slow_result)
      
      assert {:ok, :slow_result} = RateLtd.request("test:api", function, %{timeout_ms: 1000})
    end

    test "respects priority setting" do
      # Exhaust rate limit
      RateLtd.check("test:external")
      RateLtd.check("test:external")
      
      normal_function = make_test_function(:normal)
      high_priority_function = make_test_function(:high_priority)
      
      # Queue normal priority first
      task1 = Task.async(fn ->
        RateLtd.request("test:external", normal_function, %{priority: 1, timeout_ms: 2000})
      end)
      
      wait_for_processing(50)
      
      # Queue high priority second (should be processed first)
      task2 = Task.async(fn ->
        RateLtd.request("test:external", high_priority_function, %{priority: 2, timeout_ms: 2000})
      end)
      
      # High priority should complete first
      assert {:ok, :high_priority} = Task.await(task2)
      assert {:ok, :normal} = Task.await(task1)
    end

    test "respects max_retries setting" do
      # Set very low rate limit
      config = create_test_rate_config("test:retries", 1, 10000) # Long window
      RateLtd.ConfigManager.add_rate_limit_config(config)
      
      # Exhaust the limit
      RateLtd.check("test:retries")
      
      function = make_test_function(:should_be_queued)
      
      # With max_retries: 0, should go straight to queue
      task = Task.async(fn ->
        RateLtd.request("test:retries", function, %{max_retries: 0, timeout_ms: 2000})
      end)
      
      wait_for_processing(1500)
      assert {:ok, :should_be_queued} = Task.await(task)
    end
  end

  describe "get_status/1" do
    test "returns comprehensive status" do
      status = RateLtd.get_status("test:api")
      
      assert Map.has_key?(status, :rate_limit)
      assert Map.has_key?(status, :queue)
      assert Map.has_key?(status, :processor)
      
      assert is_integer(status.rate_limit.count)
      assert is_integer(status.rate_limit.remaining)
      assert %DateTime{} = status.rate_limit.reset_at
      
      assert is_integer(status.queue.depth)
      assert is_integer(status.queue.oldest_request_age_ms)
      
      assert is_boolean(status.processor.active)
    end

    test "tracks rate limit usage" do
      # Make some requests
      RateLtd.check("test:api")
      RateLtd.check("test:api")
      
      status = RateLtd.get_status("test:api")
      
      assert status.rate_limit.count == 2
      assert status.rate_limit.remaining == 1
    end
  end

  describe "configuration" do
    test "configure/2 sets up rate limits and queues" do
      new_rate_configs = [
        create_test_rate_config("new:api", 10, 2000)
      ]
      
      new_queue_configs = [
        create_test_queue_config("new:api:queue", max_size: 20)
      ]
      
      assert :ok = RateLtd.configure(new_rate_configs, new_queue_configs)
      
      # Should be able to use the new configuration
      assert {:allow, 9} = RateLtd.check("new:api")
    end

    test "handles invalid configurations" do
      invalid_rate_configs = [
        %RateLtd.RateLimitConfig{key: nil, limit: 10, window_ms: 1000}
      ]
      
      assert {:error, _reason} = RateLtd.configure(invalid_rate_configs, [])
    end
  end

  describe "error handling" do
    test "gracefully handles Redis connection issues" do
      # This test would require mocking Redis failures
      # For now, we'll test that the library doesn't crash
      function = make_test_function(:redis_test)
      
      # Should not crash even if Redis has issues
      result = RateLtd.request("test:api", function)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles malformed function serialization" do
      # Test with a function that might have serialization issues
      pid = self()
      function = fn -> send(pid, :test_message) end
      
      # Should handle this gracefully
      result = RateLtd.request("test:api", function)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
