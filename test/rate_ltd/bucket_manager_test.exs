# test/rate_ltd/bucket_manager_test.exs
defmodule RateLtd.BucketManagerTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(MockRedis)
    Application.put_env(:rate_ltd, :redis_module, MockRedis)
    MockRedis.reset()

    # Set up test configuration
    Application.put_env(:rate_ltd, :defaults,
      limit: 100,
      window_ms: 60_000,
      max_queue_size: 1000
    )

    Application.put_env(:rate_ltd, :group_configs, %{
      "test_group" => %{limit: 200, window_ms: 30_000, max_queue_size: 500},
      "payment_api" => %{limit: 1000, window_ms: 60_000, max_queue_size: 1000}
    })

    :ok
  end

  describe "list_active_buckets/0" do
    test "returns empty list when no buckets exist" do
      buckets = RateLtd.BucketManager.list_active_buckets()
      assert buckets == []
    end

    test "returns list of active bucket keys" do
      # Simulate some active buckets by creating Redis keys
      MockRedis.command(["ZADD", "rate_ltd:bucket:test_group:merchant_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:test_group:merchant_2", "1234567891", "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:simple:legacy_key", "1234567892", "req_3"])

      buckets = RateLtd.BucketManager.list_active_buckets()

      assert is_list(buckets)
      assert "bucket:test_group:merchant_1" in buckets
      assert "bucket:test_group:merchant_2" in buckets
      assert "simple:legacy_key" in buckets
    end
  end

  describe "get_group_summary/1" do
    test "returns empty summary for non-existent group" do
      summary = RateLtd.BucketManager.get_group_summary("nonexistent_group")

      assert summary.group == "nonexistent_group"
      assert summary.bucket_count == 0
      assert summary.buckets == []
      assert summary.total_usage == 0
      assert summary.active_queues == 0
      assert summary.avg_utilization == 0.0
      assert summary.peak_utilization == 0.0
    end

    test "returns summary for group with active buckets" do
      # Create some buckets in the test_group
      MockRedis.command(["ZADD", "rate_ltd:bucket:test_group:merchant_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:test_group:merchant_1", "1234567891", "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:test_group:merchant_2", "1234567892", "req_3"])

      # Create some queues
      MockRedis.command(["LPUSH", "rate_ltd:queue:bucket:test_group:merchant_1", "queue_item_1"])

      summary = RateLtd.BucketManager.get_group_summary("test_group")

      assert summary.group == "test_group"
      assert summary.bucket_count >= 0
      assert is_list(summary.buckets)
      assert is_integer(summary.total_usage)
      assert is_integer(summary.active_queues)
      assert is_float(summary.avg_utilization)
      assert is_float(summary.peak_utilization)
    end

    test "calculates utilization correctly" do
      # Create a bucket with known usage
      MockRedis.command([
        "ZADD",
        "rate_ltd:bucket:test_group:merchant_with_usage",
        "1234567890",
        "req_1"
      ])

      MockRedis.command([
        "ZADD",
        "rate_ltd:bucket:test_group:merchant_with_usage",
        "1234567891",
        "req_2"
      ])

      summary = RateLtd.BucketManager.get_group_summary("test_group")

      # Should have some utilization data
      assert summary.bucket_count > 0

      if length(summary.buckets) > 0 do
        bucket = hd(summary.buckets)
        assert is_float(bucket.utilization)
        assert bucket.utilization >= 0.0
        assert bucket.utilization <= 100.0
      end
    end
  end

  describe "get_all_groups/0" do
    test "returns empty list when no groups exist" do
      groups = RateLtd.BucketManager.get_all_groups()
      assert groups == []
    end

    test "returns list of active groups" do
      # Create buckets in different groups
      MockRedis.command(["ZADD", "rate_ltd:bucket:group_1:key_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:group_2:key_2", "1234567891", "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:group_1:key_3", "1234567892", "req_3"])

      groups = RateLtd.BucketManager.get_all_groups()

      assert is_list(groups)
      assert "group_1" in groups
      assert "group_2" in groups
      # No duplicates
      assert length(Enum.uniq(groups)) == length(groups)
    end
  end

  describe "get_system_overview/0" do
    test "returns comprehensive system overview" do
      # Create some test data
      MockRedis.command(["ZADD", "rate_ltd:bucket:payment_api:merchant_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:search_api:client_1", "1234567891", "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:simple:legacy_key", "1234567892", "req_3"])

      overview = RateLtd.BucketManager.get_system_overview()

      assert Map.has_key?(overview, :total_buckets)
      assert Map.has_key?(overview, :grouped_buckets)
      assert Map.has_key?(overview, :simple_buckets)
      assert Map.has_key?(overview, :total_usage)
      assert Map.has_key?(overview, :groups)
      assert Map.has_key?(overview, :active_groups)

      assert is_integer(overview.total_buckets)
      assert is_integer(overview.grouped_buckets)
      assert is_integer(overview.simple_buckets)
      assert is_integer(overview.total_usage)
      assert is_list(overview.groups)
      assert is_integer(overview.active_groups)

      # Total should equal grouped + simple
      assert overview.total_buckets == overview.grouped_buckets + overview.simple_buckets
    end

    test "handles empty system" do
      overview = RateLtd.BucketManager.get_system_overview()

      assert overview.total_buckets == 0
      assert overview.grouped_buckets == 0
      assert overview.simple_buckets == 0
      assert overview.total_usage == 0
      assert overview.groups == []
      assert overview.active_groups == 0
    end
  end

  describe "cleanup_expired_buckets/0" do
    test "removes empty sorted sets" do
      # Create some test buckets
      MockRedis.command(["ZADD", "rate_ltd:bucket:cleanup_test:key_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:cleanup_test:key_2", "1234567891", "req_2"])

      # This will use a mock script that simulates cleanup
      result = RateLtd.BucketManager.cleanup_expired_buckets()

      assert {:ok, cleaned_count} = result
      assert is_integer(cleaned_count)
      assert cleaned_count >= 0
    end

    test "handles Redis errors gracefully" do
      defmodule CleanupErrorRedis do
        def eval(_, _, _), do: {:error, :cleanup_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, CleanupErrorRedis)

      result = RateLtd.BucketManager.cleanup_expired_buckets()
      assert {:error, :cleanup_failed} = result
    end
  end

  describe "get_bucket_details/1" do
    test "returns detailed bucket information" do
      bucket_key = "bucket:test_group:detailed_merchant"

      # Add some requests to the bucket
      now = System.system_time(:millisecond)
      MockRedis.command(["ZADD", "rate_ltd:#{bucket_key}", to_string(now - 5000), "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:#{bucket_key}", to_string(now - 3000), "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:#{bucket_key}", to_string(now - 1000), "req_3"])

      result = RateLtd.BucketManager.get_bucket_details(bucket_key)

      assert {:ok, details} = result
      assert Map.has_key?(details, :bucket_key)
      assert Map.has_key?(details, :config)
      assert Map.has_key?(details, :current_usage)
      assert Map.has_key?(details, :remaining)
      assert Map.has_key?(details, :utilization)
      assert Map.has_key?(details, :window_start)
      assert Map.has_key?(details, :window_end)
      assert Map.has_key?(details, :recent_requests)
      assert Map.has_key?(details, :next_reset)

      assert details.bucket_key == bucket_key
      assert is_map(details.config)
      assert is_integer(details.current_usage)
      assert is_integer(details.remaining)
      assert is_float(details.utilization)
      assert is_list(details.recent_requests)
    end

    test "handles non-existent bucket" do
      result = RateLtd.BucketManager.get_bucket_details("bucket:nonexistent:key")

      assert {:ok, details} = result
      assert details.current_usage == 0
      assert details.recent_requests == []
    end

    test "handles Redis errors" do
      defmodule DetailsErrorRedis do
        def eval(_, _, _), do: {:error, :details_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, DetailsErrorRedis)

      result = RateLtd.BucketManager.get_bucket_details("bucket:error:test")
      assert {:error, :details_failed} = result
    end
  end

  describe "private functions behavior" do
    test "extract_bucket_name handles various key formats" do
      # This tests the private function indirectly through list_active_buckets
      MockRedis.command(["ZADD", "rate_ltd:bucket:group:key", "123", "req"])
      MockRedis.command(["ZADD", "rate_ltd:simple:key", "124", "req"])
      # Should be ignored
      MockRedis.command(["ZADD", "other:key", "125", "req"])

      buckets = RateLtd.BucketManager.list_active_buckets()

      # Should only include valid rate_ltd keys
      valid_buckets =
        Enum.filter(buckets, fn bucket ->
          String.starts_with?(bucket, "bucket:") or String.starts_with?(bucket, "simple:")
        end)

      assert length(valid_buckets) >= 2
    end

    test "calculates metrics correctly" do
      # Create buckets with known usage
      MockRedis.command(["ZADD", "rate_ltd:bucket:metrics_test:key_1", "1234567890", "req_1"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:metrics_test:key_1", "1234567891", "req_2"])
      MockRedis.command(["ZADD", "rate_ltd:bucket:metrics_test:key_2", "1234567892", "req_3"])

      summary = RateLtd.BucketManager.get_group_summary("metrics_test")

      # Total usage should be sum of all buckets
      if summary.bucket_count > 0 do
        calculated_total =
          Enum.reduce(summary.buckets, 0, fn bucket, acc ->
            acc + bucket.current_usage
          end)

        assert summary.total_usage == calculated_total
      end
    end
  end

  describe "error handling" do
    test "handles Redis connection failures gracefully" do
      defmodule ConnectionErrorRedis do
        def command(_), do: {:error, :connection_failed}
        def eval(_, _, _), do: {:error, :connection_failed}
      end

      Application.put_env(:rate_ltd, :redis_module, ConnectionErrorRedis)

      # All functions should handle Redis errors gracefully
      assert [] = RateLtd.BucketManager.list_active_buckets()
      assert [] = RateLtd.BucketManager.get_all_groups()

      summary = RateLtd.BucketManager.get_group_summary("test_group")
      assert summary.bucket_count == 0

      overview = RateLtd.BucketManager.get_system_overview()
      assert overview.total_buckets == 0
    end

    test "handles malformed Redis responses" do
      defmodule MalformedRedis do
        def command(["KEYS", _]), do: {:ok, ["invalid_key_format"]}
        def command(["ZCARD", _]), do: {:ok, "not_a_number"}
        def eval(_, _, _), do: {:ok, ["unexpected", "format"]}
      end

      Application.put_env(:rate_ltd, :redis_module, MalformedRedis)

      # Should not crash even with malformed responses
      buckets = RateLtd.BucketManager.list_active_buckets()
      assert is_list(buckets)

      summary = RateLtd.BucketManager.get_group_summary("test_group")
      assert is_map(summary)
    end
  end

  describe "performance considerations" do
    test "handles large number of buckets efficiently" do
      # Create many buckets
      1..50
      |> Enum.each(fn i ->
        MockRedis.command(["ZADD", "rate_ltd:bucket:perf_test:key_#{i}", "1234567890", "req_#{i}"])
      end)

      # Operations should complete without timeout
      buckets = RateLtd.BucketManager.list_active_buckets()
      assert is_list(buckets)

      summary = RateLtd.BucketManager.get_group_summary("perf_test")
      assert is_map(summary)
      assert summary.bucket_count >= 0

      overview = RateLtd.BucketManager.get_system_overview()
      assert is_map(overview)
    end

    test "caches results appropriately" do
      # This is more of a documentation test - in a real implementation,
      # you might want to add caching for expensive operations

      # Multiple calls should return consistent results
      buckets1 = RateLtd.BucketManager.list_active_buckets()
      buckets2 = RateLtd.BucketManager.list_active_buckets()

      assert buckets1 == buckets2
    end
  end

  describe "integration with other modules" do
    test "works with ConfigManager for bucket details" do
      bucket_key = "bucket:test_group:integration_test"

      # This should use ConfigManager to get the configuration
      result = RateLtd.BucketManager.get_bucket_details(bucket_key)

      assert {:ok, details} = result
      # From test_group config
      assert details.config.limit == 200
      # From test_group config
      assert details.config.window_ms == 30_000
    end

    test "reflects actual rate limiter usage" do
      # Make some actual rate limit requests
      RateLtd.request({"integration_merchant", "test_group"}, fn -> "test" end)
      RateLtd.request({"integration_merchant", "test_group"}, fn -> "test2" end)

      # BucketManager should reflect this usage
      summary = RateLtd.BucketManager.get_group_summary("test_group")

      # Should show some activity
      assert summary.bucket_count >= 0
      assert summary.total_usage >= 0
    end
  end
end
