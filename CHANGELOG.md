# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2025-11-26

### Added
- **Kubernetes Support**: Full K8s deployment with DaemonSet, ConfigMap, and RBAC manifests
  - Production-ready manifests in `k8s/` directory
  - EKS quick-start config (`infrastructure/eks-cluster.yaml`)
  - Tested on local kind clusters and AWS EKS
  - Documentation in `k8s/README.md`
- **Monitor-Only Mode**: Safe default mode that detects issues but requires human approval
  - Set via `mode = "monitor"` in circuit breaker config
  - Enforces `require_human_approval = true` automatically
- **Overhead Benchmarking**: Automated benchmarking and documentation
  - Script: `scripts/benchmark_overhead.sh`
  - Results documented in `docs/OVERHEAD.md`
  - Proven <4% CPU overhead, ~70MB RSS

### Changed
- K8s ConfigMap defaults to monitor mode and disables LLM (saves memory)
- README updated with K8s deployment instructions and overhead metrics link

### Security
- Removed `hostPort` from K8s DaemonSet to prevent unauthenticated API exposure
- Added auth token reminder in ConfigMap

### Fixed
- K8s DaemonSet: Removed `args` field to use Dockerfile CMD (fixes container exec issue)

## [0.1.1] - 2025-11-23

### Security
- API authentication improvements
- Reduced capabilities
- SHA256 verification

## [0.1.0] - Initial Release

### Added
- PSI-based system monitoring
- Circuit breaker with grace period
- LLM-powered incident analysis
- Basic API server

[0.2.0]: https://github.com/linnix-os/linnix/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/linnix-os/linnix/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/linnix-os/linnix/releases/tag/v0.1.0
