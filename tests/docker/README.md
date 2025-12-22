# Linnix Docker Integration Tests

This directory contains a comprehensive Docker Compose test suite that simulates the "Guardian vs. Victim" scenario for validating Linnix's crash-prevention capabilities.

## Overview

The test suite creates two containers:
- **Guardian (linnix-guardian)**: Runs the Linnix eBPF agent with privileged access to monitor system events
- **Victim (linnix-victim)**: Simulates untrusted workloads that may trigger circuit breakers

When the Guardian detects a dangerous condition (fork bomb, OOM risk, CPU spin), it automatically pauses the Victim container before the host crashes.

## Architecture

```
┌─────────────────────────────────────────┐
│         Host Linux Kernel               │
│  (eBPF tracepoints for fork/exec/exit)  │
└────────────┬────────────────────────────┘
             │
     ┌───────▼────────┐
     │   Guardian     │ (privileged container)
     │  - cognitod    │  - Loads eBPF programs
     │  - reflex.sh   │  - Monitors PSI/events
     │                │  - Executes docker pause
     └───────┬────────┘
             │
             │ docker pause
             ▼
     ┌───────────────┐
     │    Victim     │ (resource-limited)
     │  stress-ng    │  - 0.5 CPU cores
     │               │  - 200MB memory
     └───────────────┘
```

## Files

- **`Dockerfile.agent`**: Multi-stage build for the Linnix guardian
  - Stage 1: Rust builder with eBPF toolchain (LLVM, Clang)
  - Stage 2: Debian runtime with Docker CLI

- **`reflex.sh`**: Wrapper script that:
  - Starts cognitod in the background
  - Tails log output
  - Executes `docker pause linnix-victim` when circuit breaker triggers

- **`docker-compose.yml`**: Service orchestration
  - Guardian with host PID namespace and privileged access
  - Victim with strict resource limits (0.5 CPU, 200MB RAM)

- **`run_test.sh`**: Master test orchestrator
  - Builds and starts the stack
  - Triggers stress attacks on the victim
  - Verifies circuit breaker activation

## Prerequisites

1. **Linux kernel with eBPF support** (5.10+)
2. **BTF enabled** (`/sys/kernel/btf/vmlinux` should exist)
3. **Docker** and **docker-compose** installed
4. **Root privileges** or membership in the `docker` group

Check BTF availability:
```bash
ls -l /sys/kernel/btf/vmlinux
```

If missing, you may need to install kernel headers or upgrade your kernel.

## Quick Start

### 1. Run the Full Test Suite

```bash
cd tests/docker
./run_test.sh
```

This will:
- Build the guardian image (~5-10 minutes first time)
- Start both containers
- Wait for eBPF programs to load
- Trigger a combined stress attack (CPU + memory + fork)
- Verify the victim is paused within 60 seconds

### 2. Run Specific Attack Types

```bash
# Memory-only attack
./run_test.sh memory

# CPU-only attack
./run_test.sh cpu

# Fork bomb simulation
./run_test.sh fork

# Combined attack (default)
./run_test.sh combined
```

### 3. Manual Testing

Start services without the orchestrator:
```bash
docker-compose up -d
```

Trigger attacks manually:
```bash
# Memory pressure
docker exec linnix-victim stress-ng --vm 2 --vm-bytes 90% --timeout 30s

# Fork bomb
docker exec linnix-victim stress-ng --fork 8 --timeout 30s

# CPU saturation
docker exec linnix-victim stress-ng --cpu 4 --timeout 30s
```

Monitor logs:
```bash
# Guardian logs
docker logs -f linnix-guardian

# Victim logs
docker logs -f linnix-victim

# Check container status
docker ps -a --filter "name=linnix"
```

### 4. Cleanup

```bash
docker-compose down -v
rm -rf logs/
```

## Expected Output

### Successful Test Run

```
[INFO] Building and starting Docker Compose stack...
[SUCCESS] Services started
[INFO] Waiting for eBPF programs to load...
[SUCCESS] eBPF programs loaded successfully
[INFO] Verifying victim container is running...
[SUCCESS] Victim container is running
[INFO] Triggering combined attack on victim container...
[SUCCESS] Attack triggered: combined
[INFO] Monitoring for circuit breaker activation...
[SUCCESS] 🎯 Circuit breaker activated! Victim container is PAUSED
=========================================
✅ TEST PASSED
Guardian successfully prevented crash
=========================================
```

### What to Look for in Logs

**Guardian logs** (`docker logs linnix-guardian`):
```
[INFO] eBPF programs loaded
[DEBUG] Monitoring process events
[WARN] Fork storm detected: 120 forks/sec
[REFLEX] ⚠️  CIRCUIT BREAKER ACTIVATED: fork_storm
[REFLEX] 🛑 Pausing container: linnix-victim
[REFLEX] ✅ Container linnix-victim successfully paused
```

**Victim status**:
```bash
$ docker ps -a --filter "name=linnix-victim"
NAMES           STATUS
linnix-victim   Up 2 minutes (Paused)
```

## Troubleshooting

### eBPF Programs Fail to Load

**Symptom**: Guardian logs show "Failed to load eBPF program"

**Solutions**:
1. Check kernel version: `uname -r` (need 5.10+)
2. Verify BTF: `ls /sys/kernel/btf/vmlinux`
3. Check privileged mode: `docker inspect linnix-guardian | grep Privileged`
4. Examine capabilities: `docker exec linnix-guardian capsh --print`

### Circuit Breaker Never Triggers

**Symptom**: Victim runs full stress test without being paused

**Solutions**:
1. Check rule configuration in `configs/rules.yaml`
2. Verify reflex.sh is running: `docker exec linnix-guardian pgrep -f reflex`
3. Increase stress duration: Edit `STRESS_DURATION` in `run_test.sh`
4. Lower thresholds in `configs/rules.yaml`:
   ```yaml
   fork_storm:
     threshold: 50  # Lower from default
   ```

### Victim Container Exits (OOM Kill)

**Symptom**: Victim shows status "Exited (137)"

This means the kernel OOM killer terminated the process before Linnix could pause it. This is actually a **partial success** (the host didn't crash), but ideally we catch it earlier.

**Solutions**:
1. Reduce victim memory limit: `mem_limit: 150m` in `docker-compose.yml`
2. Increase guardian sampling rate in `configs/linnix.toml`:
   ```toml
   [telemetry]
   sample_interval_ms = 100  # Faster polling
   ```

### Docker Socket Permission Denied

**Symptom**: `reflex.sh` cannot execute `docker pause`

**Solution**: Ensure the guardian has access to Docker socket:
```bash
docker exec linnix-guardian docker ps  # Should work
```

### Build Failures

**Symptom**: Rust compilation errors during `docker-compose build`

**Solutions**:
1. Clear Docker build cache: `docker-compose build --no-cache`
2. Check available disk space: `df -h`
3. Verify Rust toolchain in builder: `docker run rust:1.75-bookworm rustc --version`

## Performance Considerations

### Resource Usage

The guardian container requires:
- **CPU**: ~2-5% baseline, up to 15% during events
- **Memory**: ~50-100MB
- **Disk**: ~500MB for image

### Scaling for Production

For real Akash Network deployments:

1. **Adjust victim limits** based on your node capacity:
   ```yaml
   cpus: '4.0'
   mem_limit: 8g
   ```

2. **Tune sampling rate** for your workload:
   ```toml
   [telemetry]
   sample_interval_ms = 500  # Balance overhead vs. responsiveness
   ```

3. **Configure cgroup hierarchy** for multi-tenant isolation:
   ```yaml
   cgroup_parent: /kubepods/burstable/pod-xyz
   ```

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Linnix Integration Test

on: [push, pull_request]

jobs:
  docker-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Run Integration Test
        run: |
          cd tests/docker
          sudo ./run_test.sh combined
        timeout-minutes: 15
      
      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: test-logs
          path: tests/docker/logs/
```

## Advanced Usage

### Custom Stress Profiles

Create a custom stress profile in `tests/docker/stress_profiles/`:

```bash
# tests/docker/stress_profiles/crypto_mining.sh
#!/bin/bash
# Simulate cryptocurrency miner behavior
stress-ng --cpu 8 --cpu-load 95 --timeout 60s &
stress-ng --vm 1 --vm-bytes 1G --vm-hang 0 --timeout 60s &
```

Then trigger it:
```bash
docker cp stress_profiles/crypto_mining.sh linnix-victim:/tmp/
docker exec linnix-victim bash /tmp/crypto_mining.sh
```

### Testing Multiple Victims

Modify `docker-compose.yml` to add more victims:

```yaml
services:
  victim-1:
    container_name: linnix-victim-1
    # ... same config ...
  
  victim-2:
    container_name: linnix-victim-2
    # ... same config ...
```

Update `reflex.sh` to pause all victims:
```bash
VICTIM_CONTAINERS="linnix-victim-1 linnix-victim-2"
for victim in $VICTIM_CONTAINERS; do
  docker pause "$victim"
done
```

## Next Steps

1. **Deploy to staging**: Test on a real Akash provider node
2. **Load testing**: Run extended stress tests (hours/days)
3. **Prometheus integration**: Export metrics to Grafana
4. **Alert routing**: Configure PagerDuty/Slack notifications

See the main [README.md](../../README.md) for production deployment guides.

## License

This test suite follows the same licensing as the main Linnix project:
- Core agent: AGPL-3.0 or commercial
- eBPF code: GPL-2.0 or MIT

## Support

For issues or questions:
- GitHub Issues: https://github.com/parth21shah/linnix/issues
- Documentation: https://github.com/parth21shah/linnix/docs
