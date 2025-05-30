defmodule MinimalTest do
  use ExUnit.Case

  test "application starts" do
    {:ok, _apps} = Application.ensure_all_started(:rate_ltd)
    assert Process.whereis(RateLtd.ConfigManager) != nil
  end

  test "basic functionality without Redis" do
    # This should work even without Redis
    config = RateLtd.RateLimitConfig.new("test", 10, 1000)
    assert config.key == "test"
  end
end
