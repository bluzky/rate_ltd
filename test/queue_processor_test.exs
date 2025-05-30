defmodule RateLtd.QueueProcessorTest do
  use ExUnit.Case
  alias RateLtd.{QueueProcessor, QueueManager, QueuedRequest, ConfigManager}
  import RateLtd.TestHelpers

  setup do
    Application.ensure_all_started(:rate_ltd)
    clear_redis()
    
    # Set up test configurations
    rate_configs = [create_test_rate_config("test:processor", 2, 1000)]
    queue_configs = [create_test_queue_config("test:processor:queue")]
    
    ConfigManager.configure(rate_configs, queue_configs)
    
    :ok
  end

  describe "queue processing" do
    test "processes queued requests when rate limit allows" do
      # Exhaust rate limit first
      RateLtd.check("test:processor")
      RateLtd.check("test:processor")
      
      # Create a request that will be queued
      caller_ref = make_ref()
      function = make_test_function(:processed_by_queue)
      
      request = QueuedRequest.new("test:processor:queue", "test:processor", function, [
        caller_pid: self(),
        caller_ref: caller_ref
      ])
      
      queue_config = create_test_queue_config("test:processor:queue")
      {:queued, _} = QueueManager.enqueue(request, queue_config)
      
      # Wait for rate limit to reset and processor to run
      wait_for_processing(1200)
      
      # Should receive the result
      receive do
        {:rate_ltd_result, ^caller_ref, {:ok, :processed_by_queue}} -> :ok
      after
        3000 -> flunk("Did not receive processed result")
      end
    end

    test "handles function execution errors" do
      # Exhaust rate limit first
      RateLtd.check("test:processor")
      RateLtd.check("test:processor")
      
      caller_ref = make_ref()
      error_function = make_error_function("processing error")
      
      request = QueuedRequest.new("test:processor:queue", "test:processor", error_function, [
        caller_pid: self(),
        caller_ref: caller_ref
      ])
      
      queue_config = create_test_queue_config("test:processor:queue")
      {:queued, _} = QueueManager.enqueue(request, queue_config)
      
      # Wait for processing
      wait_for_processing(1200)
      
      # Should receive the error
      receive do
        {:rate_ltd_result, ^caller_ref, {:error, {:function_error, _}}} -> :ok
      after
        3000 -> flunk("Did not receive error result")
      end
    end

    test "removes expired requests during processing" do
      # Create an already expired request
      expired_request = %QueuedRequest{
        id: UUID.uuid4(),
        queue_name: "test:processor:queue",
        rate_limit_key: "test:processor",
        function: make_test_function(:expired),
        queued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), -1000, :millisecond),
        priority: 1,
        caller_pid: self(),
        caller_ref: make_ref()
      }
      
      queue_config = create_test_queue_config("test:processor:queue")
      QueueManager.enqueue(expired_request, queue_config)
      
      # Add a valid request
      valid_request = QueuedRequest.new("test:processor:queue", "test:processor", make_test_function(:valid))
      QueueManager.enqueue(valid_request, queue_config)
      
      # Wait for processing
      wait_for_processing(200)
      
      # Queue should have processed and removed the expired request
      status = QueueManager.get_status("test:processor:queue")
      assert status.depth <= 1  # Should have removed expired request
    end

    test "respects rate limits when processing" do
      # Exhaust rate limit
      RateLtd.check("test:processor")
      RateLtd.check("test:processor")
      
      # Add multiple requests
      request1 = QueuedRequest.new("test:processor:queue", "test:processor", make_test_function(:first))
      request2 = QueuedRequest.new("test:processor:queue", "test:processor", make_test_function(:second))
      
      queue_config = create_test_queue_config("test:processor:queue")
      QueueManager.enqueue(request1, queue_config)
      QueueManager.enqueue(request2, queue_config)
      
      # Wait for one processing cycle (should only process one due to rate limit)
      wait_for_processing(200)
      
      # Should still have requests in queue
      status = QueueManager.get_status("test:processor:queue")
      initial_depth = status.depth
      
      # Wait for rate limit to reset
      wait_for_processing(1000)
      
      # Now should have processed more
      status = QueueManager.get_status("test:processor:queue")
      assert status.depth < initial_depth
    end
  end

  describe "processor control" do
    test "get_status returns processor information" do
      status = QueueProcessor.get_status()
      
      assert Map.has_key?(status, :queues_processed)
      assert Map.has_key?(status, :last_run)
      assert Map.has_key?(status, :active)
      assert Map.has_key?(status, :stats)
      
      assert is_integer(status.queues_processed)
      assert is_boolean(status.active)
    end

    test "pause and resume processor" do
      # Pause the processor
      assert :ok = QueueProcessor.pause()
      
      status = QueueProcessor.get_status()
      assert status.active == false
      
      # Resume the processor
      assert :ok = QueueProcessor.resume()
      
      wait_for_processing(50)
      
      status = QueueProcessor.get_status()
      assert status.active == true
    end

    test "paused processor does not process queues" do
      # Pause processor
      QueueProcessor.pause()
      
      # Add a request
      request = QueuedRequest.new("test:processor:queue", "test:processor", make_test_function())
      queue_config = create_test_queue_config("test:processor:queue")
      QueueManager.enqueue(request, queue_config)
      
      # Wait and check that it wasn't processed
      wait_for_processing(300)
      
      status = QueueManager.get_status("test:processor:queue")
      assert status.depth == 1  # Should still be there
      
      # Resume and verify processing
      QueueProcessor.resume()
      wait_for_processing(200)
      
      status = QueueManager.get_status("test:processor:queue")
      assert status.depth == 0  # Should be processed now
    end
  end

  describe "priority processing" do
    test "processes high priority requests first" do
      # Set up queue with priority support
      priority_queue_config = create_test_queue_config("test:priority:queue", enable_priority: true)
      ConfigManager.add_queue_config(priority_queue_config)
      
      # Add rate limit config for priority testing
      priority_rate_config = create_test_rate_config("test:priority", 1, 2000)
      ConfigManager.add_rate_limit_config(priority_rate_config)
      
      # Exhaust rate limit
      RateLtd.check("test:priority")
      
      # Add normal priority request first
      normal_ref = make_ref()
      normal_request = QueuedRequest.new("test:priority:queue", "test:priority", 
        make_test_function(:normal), [
          priority: 1,
          caller_pid: self(),
          caller_ref: normal_ref
        ])
      
      QueueManager.enqueue(normal_request, priority_queue_config)
      
      wait_for_processing(50)
      
      # Add high priority request second
      high_ref = make_ref()
      high_request = QueuedRequest.new("test:priority:queue", "test:priority", 
        make_test_function(:high), [
          priority: 2,
          caller_pid: self(),
          caller_ref: high_ref
        ])
      
      QueueManager.enqueue(high_request, priority_queue_config)
      
      # Wait for processing
      wait_for_processing(2200)
      
      # High priority should be processed first
      receive do
        {:rate_ltd_result, ^high_ref, {:ok, :high}} -> 
          # Good, high priority came first
          receive do
            {:rate_ltd_result, ^normal_ref, {:ok, :normal}} -> :ok
          after
            3000 -> flunk("Normal priority request not processed")
          end
      after
        3000 -> flunk("High priority request not processed first")
      end
    end
  end

  describe "error handling" do
    test "handles missing rate limit configuration gracefully" do
      # Create request for non-configured rate limit
      request = QueuedRequest.new("test:unconfigured:queue", "test:unconfigured", make_test_function(:unconfigured))
      queue_config = create_test_queue_config("test:unconfigured:queue")
      
      # Should still process the request (processor should handle missing config)
      QueueManager.enqueue(request, queue_config)
      
      wait_for_processing(200)
      
      # Request should be processed despite missing rate limit config
      status = QueueManager.get_status("test:unconfigured:queue")
      assert status.depth == 0
    end

    test "continues processing other queues when one queue has errors" do
      # Set up two different queues
      queue_config1 = create_test_queue_config("test:error1:queue")
      queue_config2 = create_test_queue_config("test:error2:queue")
      ConfigManager.add_queue_config(queue_config1)
      ConfigManager.add_queue_config(queue_config2)
      
      # Add requests to both queues
      error_request = QueuedRequest.new("test:error1:queue", "test:error1", make_error_function())
      normal_request = QueuedRequest.new("test:error2:queue", "test:error2", make_test_function())
      
      QueueManager.enqueue(error_request, queue_config1)
      QueueManager.enqueue(normal_request, queue_config2)
      
      wait_for_processing(200)
      
      # Both should be processed (error one removed, normal one processed)
      status1 = QueueManager.get_status("test:error1:queue")
      status2 = QueueManager.get_status("test:error2:queue")
      
      assert status1.depth == 0  # Error request removed
      assert status2.depth == 0  # Normal request processed
    end
  end
end
