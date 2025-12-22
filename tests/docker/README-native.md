# Native Docker Enforcement - Circuit Breaker Implementation

This directory contains the **native Docker enforcement** implementation for Linnix, eliminating the need for shell wrapper scripts.

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Linnix Cognitod (Rust)                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │ eBPF Probes  │─▶│ Rule Engine  │─▶│ DockerEnforcer  │   │
│  │ (fork/exec)  │  │ (YAML rules) │  │  (Handler)      │   │
│  └──────────────┘  └──────────────┘  └─────────────────┘   │
│         │                  │                    │           │
│    Fork Events         Violations           Actions         │
└─────────┼──────────────────┼────────────────────┼───────────┘
          ▼                  ▼                    ▼
    Kernel Trace    fork_storm detected    docker pause victim
```

### Key Features

1. **Direct Rust Implementation**
   - No shell scripts or wrapper processes
   - Type-safe Docker API calls via `std::process::Command`
   - Integrated with cognitod's Handler trait

2. **Config-Driven Policies**
   - Target container selection
   - Action types: pause, stop, kill, restart
   - Rule-specific action overrides
   - Trigger pattern matching

3. **Safety Mechanisms**
   - Cooldown period between actions (default: 60s)
   - Rate limiting (max actions per hour)
   - Grace period before first action
   - Action history tracking

4. **PSI Integration**
   - Monitors CPU and memory Pressure Stall Information
   - Dual-signal detection: high usage + high PSI = thrashing
   - Separate thresholds for CPU vs memory enforcement

## File Structure

```
tests/docker/
├── Dockerfile.native              # Native enforcement container build
├── docker-compose.native.yml      # Services without wrapper
├── linnix-native.toml             # Config with enforcement enabled
├── test_native.sh                 # Automated integration test
└── README-native.md               # This file

cognitod/src/handler/
└── docker.rs                      # DockerEnforcer implementation
```

## Configuration

### Basic Setup

Add to `linnix.toml`:

```toml
[docker_enforcement]
enabled = true
target_container = "my-victim-container"
default_action = "pause"
trigger_patterns = ["fork_storm", "oom_risk", "cpu_spin"]
grace_period_secs = 5
cooldown_secs = 60
max_actions_per_hour = 10
```

### Rule-Specific Actions

Override actions per rule:

```toml
[docker_enforcement.rule_actions]
fork_storm = "pause"        # Pause on fork bombs
fork_storm_demo = "pause"   # Testing rule
oom_risk = "kill"           # Kill on OOM risk
cpu_spin = "pause"          # Pause on CPU spin
```

### CLI Override

Start cognitod with CLI target:

```bash
# Use config
cognitod --handler docker

# Override container name
cognitod --handler docker:my-container
```

## Testing

### Automated Test

Run full integration test:

```bash
cd tests/docker
./test_native.sh
```

This will:
1. Build guardian image with native enforcement
2. Start guardian + victim containers
3. Monitor for automatic circuit breaker activation
4. Validate enforcement actions

### Manual Testing

**Step 1: Build Image**

```bash
cd tests/docker
docker build -f Dockerfile.native -t linnix-guardian-native:latest ../../
```

**Step 2: Start Services**

```bash
docker-compose -f docker-compose.native.yml up -d
```

**Step 3: Monitor Logs**

```bash
# Watch for enforcement events
docker logs -f linnix-guardian-native | grep -E "docker_enforcer|fork_storm"

# Check victim status
docker ps --filter "name=linnix-victim"
```

**Step 4: Trigger Fork Storm**

```bash
# Install stress-ng if needed
docker exec linnix-victim sh -c 'apt-get update && apt-get install -y stress-ng'

# Trigger fork bomb
docker exec linnix-victim stress-ng --fork 8 --timeout 30s
```

**Expected Output:**

```
[INFO  cognitod::handler::docker] [docker_enforcer] Executing: docker pause linnix-victim (reason: fork_storm_demo)
[INFO  cognitod::handler::docker] [docker_enforcer] ✅ Successfully paused container: linnix-victim
```

## Implementation Details

### DockerEnforcer Handler

**Location:** `cognitod/src/handler/docker.rs`

**Key Methods:**

- `on_event()` - Processes individual fork/exec events (currently no-op to prevent spam)
- `on_snapshot()` - Monitors system-wide PSI metrics for thrashing
- `execute_action()` - Executes Docker commands with rate limiting
- `check_snapshot_conditions()` - Evaluates PSI thresholds

**Handler Registration:**

```rust
// In main.rs
if let Some(docker_cfg) = config.docker_enforcement.clone() {
    if docker_cfg.enabled {
        let enforcer = handler::docker::DockerEnforcer::new(docker_cfg);
        handler_list.register(enforcer);
    }
}
```

### Action Flow

1. **Detection**
   - eBPF probe captures fork event
   - Event flows through cognitod pipeline
   - RuleEngine evaluates against YAML rules

2. **Rule Match**
   - Rule detector (e.g., `fork_storm_demo`) triggers
   - Alert broadcast to registered handlers
   - DockerEnforcer receives notification

3. **Enforcement Decision**
   - Check if rule matches trigger patterns
   - Verify rate limits and cooldown
   - Determine action type (rule override or default)

4. **Execution**
   - Execute `docker <action> <container>` command
   - Log success/failure
   - Record action in history

### Rate Limiting

**Cooldown Period:**
- Prevents action spam during transient spikes
- Default: 60 seconds between actions
- Configurable via `cooldown_secs`

**Hourly Limit:**
- Prevents flapping containers
- Default: 10 actions per hour
- Configurable via `max_actions_per_hour`

**Implementation:**

```rust
struct ActionHistory {
    last_action_time: Option<SystemTime>,
    actions_in_hour: Vec<SystemTime>,
}

fn can_take_action(&mut self, cooldown: Duration, max_per_hour: u32) -> bool {
    // Check cooldown
    if let Some(last) = self.last_action_time {
        if now.duration_since(last) < cooldown {
            return false;
        }
    }
    
    // Check hourly rate limit
    self.actions_in_hour.retain(|t| t > &one_hour_ago);
    if self.actions_in_hour.len() >= max_per_hour {
        return false;
    }
    
    true
}
```

## Comparison: Wrapper vs Native

### Wrapper Approach (reflex.sh)

**Pros:**
- Simple shell script
- Easy to understand and modify
- No Rust code changes

**Cons:**
- Extra process overhead
- Shell parsing of log output
- No type safety
- Difficult to test
- No rate limiting

**Example:**
```bash
tail -F /dev/stdout | grep -E "fork_storm|oom_risk" | while read line; do
    docker pause linnix-victim
done
```

### Native Approach (docker.rs)

**Pros:**
- Type-safe Rust implementation
- Integrated with cognitod Handler trait
- Built-in rate limiting and cooldown
- Config-driven policies
- Rule-specific action overrides
- Testable with unit tests
- Better error handling

**Cons:**
- Requires Rust code changes
- Slightly more complex initial setup

**Example:**
```rust
async fn execute_action(&self, action: &ContainerAction, reason: &str) -> Result<String, String> {
    // Check rate limits
    if !self.history.can_take_action(cooldown, max_per_hour) {
        return Err("Rate limit exceeded".to_string());
    }
    
    // Execute Docker command
    Command::new("docker")
        .arg("pause")
        .arg(&self.config.target_container)
        .output()?;
}
```

## Production Deployment

### Kubernetes DaemonSet

Deploy as DaemonSet with enforcement enabled:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: linnix-guardian
spec:
  template:
    spec:
      hostPID: true
      hostNetwork: true
      containers:
      - name: cognitod
        image: linnix-guardian-native:latest
        securityContext:
          privileged: true
        volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
        - name: config
          mountPath: /etc/linnix/linnix.toml
          subPath: linnix.toml
```

### Configuration Management

**Production Config (`/etc/linnix/linnix.toml`):**

```toml
[docker_enforcement]
enabled = true
target_container = "workload-*"  # Pattern matching (if supported)
default_action = "pause"
trigger_patterns = ["fork_storm", "oom_risk", "memory_leak"]
grace_period_secs = 10    # Higher for prod
cooldown_secs = 300       # 5 minutes between actions
max_actions_per_hour = 6  # Conservative limit

[docker_enforcement.rule_actions]
fork_storm = "pause"
oom_risk = "stop"
memory_leak = "restart"
```

### Monitoring

**Metrics to Track:**

- Actions taken per hour
- Actions blocked by rate limiting
- Container restart counts
- Time to circuit breaker activation
- False positive rate

**Prometheus Queries:**

```promql
# Actions per hour
rate(linnix_docker_enforcer_actions_total[1h])

# Rate limit hits
linnix_docker_enforcer_rate_limited_total

# Victim pause events
changes(container_state{name="linnix-victim", state="paused"}[1h])
```

### Alerting

Alert on excessive enforcement:

```yaml
- alert: LinuxExcessiveEnforcement
  expr: rate(linnix_docker_enforcer_actions_total[1h]) > 10
  annotations:
    summary: "Circuit breaker triggered too frequently"
    description: "{{ $value }} enforcement actions in past hour"
```

## Troubleshooting

### Enforcement Not Activating

**Check 1: Config enabled**
```bash
docker exec linnix-guardian-native cat /etc/linnix/linnix.toml | grep -A 5 docker_enforcement
```

**Check 2: Handler registered**
```bash
docker logs linnix-guardian-native 2>&1 | grep "Docker enforcement handler"
```

**Check 3: Rule violations**
```bash
docker logs linnix-guardian-native 2>&1 | grep "fork_storm_demo"
```

**Check 4: Rate limiting**
```bash
docker logs linnix-guardian-native 2>&1 | grep "Rate limit exceeded"
```

### Container Not Pausing

**Check 1: Docker socket mounted**
```bash
docker inspect linnix-guardian-native | grep "docker.sock"
```

**Check 2: Container name correct**
```bash
docker ps --filter "name=linnix-victim"
```

**Check 3: Docker command succeeding**
```bash
docker exec linnix-guardian-native docker pause linnix-victim
```

### High Action Rate

If actions are triggering too frequently:

1. **Increase cooldown:** `cooldown_secs = 300`
2. **Reduce max per hour:** `max_actions_per_hour = 5`
3. **Adjust rule thresholds:** Lower sensitivity in `rules.yaml`
4. **Add grace period:** `grace_period_secs = 15`

## Future Enhancements

### Planned Features

- [ ] Container pattern matching (pause multiple containers)
- [ ] Kubernetes pod enforcement (via kubectl)
- [ ] Gradual enforcement (warn → pause → stop → kill)
- [ ] Enforcement history API endpoint
- [ ] Grafana dashboard for enforcement metrics
- [ ] Integration with PagerDuty/Slack for action notifications
- [ ] Dry-run mode (log actions without executing)
- [ ] User confirmation prompts for critical actions

### API Extension

Potential HTTP endpoints:

```
GET  /enforcement/history         - List recent actions
POST /enforcement/override/:id    - Manual enforcement
GET  /enforcement/config          - View current policy
PUT  /enforcement/config          - Update policy (hot reload)
POST /enforcement/pause           - Temporary disable
```

## References

- Main README: `../../README.md`
- Handler trait: `../../cognitod/src/handler/mod.rs`
- Rule engine: `../../cognitod/src/alerts.rs`
- Config schema: `../../cognitod/src/config.rs`
- Wrapper implementation: `./reflex.sh` (legacy)
- Integration test: `./test_native.sh`

## License

AGPL-3.0 (see `../../LICENSE`)
