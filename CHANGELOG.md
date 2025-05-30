# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-05-30

### Added
- Initial release of RateLtd
- Distributed rate limiting with Redis backend
- Support for sliding window, fixed window, and token bucket algorithms
- Request queueing with configurable size and timeout limits
- Background queue processor with automatic retry mechanisms
- Priority queue support for request prioritization
- Async and blocking request modes
- Comprehensive configuration management
- Redis connection pooling with automatic reconnection
- Graceful degradation when Redis is unavailable
- Telemetry integration for monitoring and observability
- Lua scripts for atomic Redis operations
- Support for multiple rate limit configurations per application
- Request timeout and TTL management
- Queue introspection and monitoring capabilities
- Configurable overflow strategies (reject vs drop oldest)
- Automatic cleanup of expired requests
- Application-level interface with simple API
- Comprehensive test suite with unit and integration tests
- Detailed documentation and examples
- Support for OTP application structure
- Supervisor tree for fault tolerance
- Proper error handling throughout the system

### Technical Features
- Redis Sorted Sets for sliding window algorithm implementation
- Atomic operations via Lua scripts for consistency
- Connection pooling using Poolboy for high throughput
- GenServer-based architecture for reliability
- Structured logging with appropriate levels
- Memory-efficient Redis key patterns
- Serialization/deserialization of queued functions
- Support for process communication in async mode
- Configurable polling intervals for queue processing
- Batch processing capabilities for improved performance

### Documentation
- Comprehensive README with usage examples
- Detailed API documentation
- Configuration reference guide
- Performance tuning recommendations
- Production deployment considerations
- Testing strategies and examples
- Integration examples with Phoenix, Oban, and other frameworks
- Monitoring and alerting setup guides
- Troubleshooting documentation

[Unreleased]: https://github.com/your-username/rate_ltd/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-username/rate_ltd/releases/tag/v0.1.0
