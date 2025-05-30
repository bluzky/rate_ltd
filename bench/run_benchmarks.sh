#!/usr/bin/env bash

# RateLtd Benchmark Runner
# Runs performance benchmarks for the RateLtd library

set -e

echo "RateLtd Benchmark Runner"
echo "========================"
echo ""

# Check if Redis is running
if ! redis-cli ping > /dev/null 2>&1; then
    echo "Error: Redis is not running. Please start Redis before running benchmarks."
    echo "Try: redis-server"
    exit 1
fi

echo "✓ Redis is running"

# Check if dependencies are compiled
if [ ! -d "_build" ]; then
    echo "Compiling dependencies..."
    mix deps.get
    mix compile
fi

echo "✓ Dependencies compiled"
echo ""

# Run the benchmarks
echo "Starting benchmarks..."
echo ""

iex -S mix -e "RateLtd.Benchmark.run_all_benchmarks()"
