defmodule RateLtd.Benchmark do
  @moduledoc """
  Performance benchmarks for RateLtd.
  """

  alias RateLtd.{RateLimiter, RateLimitConfig}

  def run_rate_limiter_benchmark do
    # Clear Redis first
    RateLtd.RedisManager.command(["FLUSHDB"])
    
    config = RateLimitConfig.new("bench:test", 1000, 60_000)
    
    # Warm up
    for _ <- 1..100 do
      RateLimiter.check_rate("bench:test", config)
    end
    
    # Benchmark single-threaded performance
    IO.puts("=== Single-threaded Rate Limiter Benchmark ===")
    
    {time_us, _result} = :timer.tc(fn ->
      for _ <- 1..10_000 do
        RateLimiter.check_rate("bench:test", config)
      end
    end)
    
    ops_per_sec = 10_000 / (time_us / 1_000_000)
    IO.puts("Rate limiter: #{:erlang.float_to_binary(ops_per_sec, decimals: 0)} ops/sec")
    
    # Benchmark concurrent performance
    IO.puts("\n=== Concurrent Rate Limiter Benchmark ===")
    
    num_processes = 50
    ops_per_process = 200
    
    {time_us, _results} = :timer.tc(fn ->
      1..num_processes
      |> Enum.map(fn i ->
        Task.async(fn ->
          config = RateLimitConfig.new("bench:concurrent:#{i}", 1000, 60_000)
          for _ <- 1..ops_per_process do
            RateLimiter.check_rate("bench:concurrent:#{i}", config)
          end
        end)
      end)
      |> Enum.map(&Task.await/1)
    end)
    
    total_ops = num_processes * ops_per_process
    concurrent_ops_per_sec = total_ops / (time_us / 1_000_000)
    IO.puts("Concurrent rate limiter: #{:erlang.float_to_binary(concurrent_ops_per_sec, decimals: 0)} ops/sec")
    
    # Memory usage test
    IO.puts("\n=== Memory Usage Test ===")
    memory_before = :erlang.memory(:total)
    
    # Create many rate limit entries
    for i <- 1..10_000 do
      config = RateLimitConfig.new("bench:memory:#{i}", 100, 60_000)
      RateLimiter.check_rate("bench:memory:#{i}", config)
    end
    
    memory_after = :erlang.memory(:total)
    memory_diff = memory_after - memory_before
    IO.puts("Memory used for 10,000 rate limit entries: #{div(memory_diff, 1024)} KB")
  end

  def run_queue_benchmark do
    IO.puts("\n=== Queue Performance Benchmark ===")
    
    # Clear Redis
    RateLtd.RedisManager.command(["FLUSHDB"])
    
    queue_config = RateLtd.QueueConfig.new("bench:queue", max_size: 50_000)
    
    # Benchmark enqueue performance
    {enqueue_time_us, _} = :timer.tc(fn ->
      for i <- 1..1_000 do
        request = RateLtd.QueuedRequest.new("bench:queue", "bench:key", fn -> i end)
        RateLtd.QueueManager.enqueue(request, queue_config)
      end
    end)
    
    enqueue_ops_per_sec = 1_000 / (enqueue_time_us / 1_000_000)
    IO.puts("Queue enqueue: #{:erlang.float_to_binary(enqueue_ops_per_sec, decimals: 0)} ops/sec")
    
    # Benchmark dequeue performance
    {dequeue_time_us, _} = :timer.tc(fn ->
      for _ <- 1..1_000 do
        RateLtd.QueueManager.dequeue("bench:queue")
      end
    end)
    
    dequeue_ops_per_sec = 1_000 / (dequeue_time_us / 1_000_000)
    IO.puts("Queue dequeue: #{:erlang.float_to_binary(dequeue_ops_per_sec, decimals: 0)} ops/sec")
  end

  def run_end_to_end_benchmark do
    IO.puts("\n=== End-to-End Request Benchmark ===")
    
    # Setup
    rate_configs = [
      RateLtd.RateLimitConfig.new("bench:e2e", 10_000, 60_000)
    ]
    queue_configs = [
      RateLtd.QueueConfig.new("bench:e2e:queue", max_size: 5_000)
    ]
    
    RateLtd.configure(rate_configs, queue_configs)
    
    # Benchmark immediate execution (within rate limit)
    {immediate_time_us, _} = :timer.tc(fn ->
      for i <- 1..1_000 do
        {:ok, _result} = RateLtd.request("bench:e2e", fn -> i * 2 end)
      end
    end)
    
    immediate_ops_per_sec = 1_000 / (immediate_time_us / 1_000_000)
    IO.puts("Immediate execution: #{:erlang.float_to_binary(immediate_ops_per_sec, decimals: 0)} ops/sec")
    
    # Benchmark async queueing
    {async_time_us, _} = :timer.tc(fn ->
      for i <- 1..500 do
        case RateLtd.request("bench:e2e", fn -> i * 3 end, %{async: true}) do
          {:ok, _} -> :ok
          {:queued, _} -> :ok
          {:error, _} -> :ok
        end
      end
    end)
    
    async_ops_per_sec = 500 / (async_time_us / 1_000_000)
    IO.puts("Async requests: #{:erlang.float_to_binary(async_ops_per_sec, decimals: 0)} ops/sec")
  end

  def run_stress_test do
    IO.puts("\n=== Stress Test ===")
    
    # Setup high-volume configuration
    rate_configs = [
      RateLtd.RateLimitConfig.new("stress:test", 1000, 10_000)  # High rate limit, short window
    ]
    queue_configs = [
      RateLtd.QueueConfig.new("stress:test:queue", max_size: 10_000)
    ]
    
    RateLtd.configure(rate_configs, queue_configs)
    
    num_processes = 100
    requests_per_process = 100
    
    IO.puts("Starting stress test: #{num_processes} processes, #{requests_per_process} requests each")
    
    start_time = System.monotonic_time(:millisecond)
    
    tasks = 
      1..num_processes
      |> Enum.map(fn process_id ->
        Task.async(fn ->
          results = %{success: 0, queued: 0, errors: 0}
          
          Enum.reduce(1..requests_per_process, results, fn request_id, acc ->
            case RateLtd.request("stress:test", fn -> 
              Process.sleep(1) # Simulate some work
              {process_id, request_id}
            end, %{async: true, timeout_ms: 5_000}) do
              {:ok, _} -> %{acc | success: acc.success + 1}
              {:queued, _} -> %{acc | queued: acc.queued + 1}
              {:error, _} -> %{acc | errors: acc.errors + 1}
            end
          end)
        end)
      end)
    
    results = Enum.map(tasks, &Task.await(&1, 30_000))
    end_time = System.monotonic_time(:millisecond)
    
    total_results = Enum.reduce(results, %{success: 0, queued: 0, errors: 0}, fn result, acc ->
      %{
        success: acc.success + result.success,
        queued: acc.queued + result.queued,
        errors: acc.errors + result.errors
      }
    end)
    
    duration_ms = end_time - start_time
    total_requests = num_processes * requests_per_process
    
    IO.puts("Stress test completed in #{duration_ms}ms")
    IO.puts("Total requests: #{total_requests}")
    IO.puts("Successful: #{total_results.success}")
    IO.puts("Queued: #{total_results.queued}")
    IO.puts("Errors: #{total_results.errors}")
    IO.puts("Throughput: #{:erlang.float_to_binary(total_requests / (duration_ms / 1000), decimals: 1)} req/sec")
    
    # Wait for queued requests to complete
    IO.puts("Waiting for queued requests to complete...")
    Process.sleep(5_000)
    
    status = RateLtd.get_status("stress:test")
    IO.puts("Remaining queue depth: #{status.queue.depth}")
  end

  def run_all_benchmarks do
    IO.puts("Starting RateLtd Performance Benchmarks")
    IO.puts("======================================")
    
    run_rate_limiter_benchmark()
    run_queue_benchmark()
    run_end_to_end_benchmark()
    run_stress_test()
    
    IO.puts("\n======================================")
    IO.puts("All benchmarks completed!")
  end
end
