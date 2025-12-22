use crate::handler::Handler;
use crate::types::SystemSnapshot;
use crate::ProcessEvent;
use async_trait::async_trait;
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::RwLock;

/// Docker container enforcement actions
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ContainerAction {
    /// Pause container (SIGSTOP to all processes)
    Pause,
    /// Stop container gracefully (SIGTERM then SIGKILL)
    Stop,
    /// Kill container immediately (SIGKILL)
    Kill,
    /// Restart container
    Restart,
}

/// Docker enforcement policy configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DockerEnforcementConfig {
    /// Enable enforcement (default: false for safety)
    #[serde(default)]
    pub enabled: bool,

    /// Default action to take (pause, stop, kill, restart)
    #[serde(default = "default_action")]
    pub default_action: ContainerAction,

    /// Container name or ID to protect (e.g., "linnix-victim")
    pub target_container: String,

    /// Trigger patterns to watch for in rule names
    /// Examples: ["fork_storm", "oom_risk", "cpu_spin"]
    #[serde(default)]
    pub trigger_patterns: Vec<String>,

    /// Grace period in seconds before taking action
    #[serde(default = "default_grace_period")]
    pub grace_period_secs: u64,

    /// Cooldown period in seconds between actions
    #[serde(default = "default_cooldown")]
    pub cooldown_secs: u64,

    /// Maximum actions per hour to prevent flapping
    #[serde(default = "default_max_actions_per_hour")]
    pub max_actions_per_hour: u32,

    /// Override actions per rule name
    /// Example: {"fork_storm": "pause", "oom_risk": "kill"}
    #[serde(default)]
    pub rule_actions: HashMap<String, ContainerAction>,
}

fn default_action() -> ContainerAction {
    ContainerAction::Pause
}

fn default_grace_period() -> u64 {
    5
}

fn default_cooldown() -> u64 {
    60
}

fn default_max_actions_per_hour() -> u32 {
    10
}

#[derive(Debug)]
struct ActionHistory {
    last_action_time: Option<SystemTime>,
    actions_in_hour: Vec<SystemTime>,
}

impl ActionHistory {
    fn new() -> Self {
        Self {
            last_action_time: None,
            actions_in_hour: Vec::new(),
        }
    }

    fn can_take_action(&mut self, cooldown: Duration, max_per_hour: u32) -> bool {
        let now = SystemTime::now();

        // Check cooldown
        if let Some(last) = self.last_action_time {
            if now.duration_since(last).unwrap_or(Duration::ZERO) < cooldown {
                return false;
            }
        }

        // Clean up actions older than 1 hour
        let one_hour_ago = now - Duration::from_secs(3600);
        self.actions_in_hour
            .retain(|t| t > &one_hour_ago);

        // Check rate limit
        if self.actions_in_hour.len() >= max_per_hour as usize {
            return false;
        }

        true
    }

    fn record_action(&mut self) {
        let now = SystemTime::now();
        self.last_action_time = Some(now);
        self.actions_in_hour.push(now);
    }
}

/// Docker enforcement handler for circuit breaker actions
pub struct DockerEnforcer {
    config: DockerEnforcementConfig,
    history: Arc<RwLock<ActionHistory>>,
}

impl DockerEnforcer {
    pub fn new(config: DockerEnforcementConfig) -> Self {
        info!(
            "[docker_enforcer] Initialized: enabled={} target={} action={:?}",
            config.enabled, config.target_container, config.default_action
        );
        if !config.trigger_patterns.is_empty() {
            info!(
                "[docker_enforcer] Watching patterns: {:?}",
                config.trigger_patterns
            );
        }

        Self {
            config,
            history: Arc::new(RwLock::new(ActionHistory::new())),
        }
    }

    /// Check if a rule name matches any trigger pattern
    fn matches_trigger(&self, rule_name: &str) -> bool {
        if self.config.trigger_patterns.is_empty() {
            return true; // No patterns = match all
        }

        self.config
            .trigger_patterns
            .iter()
            .any(|pattern| rule_name.contains(pattern))
    }

    /// Get the appropriate action for a rule
    fn get_action(&self, rule_name: &str) -> ContainerAction {
        self.config
            .rule_actions
            .get(rule_name)
            .cloned()
            .unwrap_or_else(|| self.config.default_action.clone())
    }

    /// Execute Docker container action
    async fn execute_action(
        &self,
        action: &ContainerAction,
        reason: &str,
    ) -> Result<String, String> {
        if !self.config.enabled {
            let msg = format!(
                "[docker_enforcer] WOULD {} {} (reason: {}) - enforcement disabled",
                action_verb(action),
                self.config.target_container,
                reason
            );
            info!("{}", msg);
            return Ok(msg);
        }

        // Check rate limits
        {
            let mut history = self.history.write().await;
            let cooldown = Duration::from_secs(self.config.cooldown_secs);
            let max_per_hour = self.config.max_actions_per_hour;

            if !history.can_take_action(cooldown, max_per_hour) {
                let msg = format!(
                    "[docker_enforcer] Rate limit exceeded for {} (cooldown or max/hour)",
                    self.config.target_container
                );
                warn!("{}", msg);
                return Err(msg);
            }

            history.record_action();
        }

        let container = &self.config.target_container;
        let docker_cmd = match action {
            ContainerAction::Pause => "pause",
            ContainerAction::Stop => "stop",
            ContainerAction::Kill => "kill",
            ContainerAction::Restart => "restart",
        };

        info!(
            "[docker_enforcer] Executing: docker {} {} (reason: {})",
            docker_cmd, container, reason
        );

        let output = Command::new("docker")
            .arg(docker_cmd)
            .arg(container)
            .output();

        match output {
            Ok(result) if result.status.success() => {
                let msg = format!(
                    "[docker_enforcer] ✅ Successfully {}d container: {}",
                    docker_cmd, container
                );
                info!("{}", msg);
                Ok(msg)
            }
            Ok(result) => {
                let stderr = String::from_utf8_lossy(&result.stderr);
                let msg = format!(
                    "[docker_enforcer] ❌ Failed to {} {}: {}",
                    docker_cmd, container, stderr
                );
                error!("{}", msg);
                Err(msg)
            }
            Err(e) => {
                let msg = format!(
                    "[docker_enforcer] ❌ Command failed: docker {} {}: {}",
                    docker_cmd, container, e
                );
                error!("{}", msg);
                Err(msg)
            }
        }
    }

    /// Check system snapshot for PSI-based circuit breaker conditions
    async fn check_snapshot_conditions(&self, snapshot: &SystemSnapshot) {
        // Extract PSI metrics from SystemSnapshot
        let cpu_psi = snapshot.psi_cpu_some_avg10;
        let mem_psi_full = snapshot.psi_memory_full_avg10;
        let cpu_usage = snapshot.cpu_percent;

        // High thresholds for automatic intervention
        let cpu_psi_high = cpu_psi > 40.0;
        let mem_psi_high = mem_psi_full > 30.0;
        let cpu_usage_high = cpu_usage > 90.0;

        if cpu_psi_high && cpu_usage_high {
            let reason = format!(
                "CPU thrashing detected: usage={:.1}% psi={:.1}%",
                cpu_usage, cpu_psi
            );
            info!("[docker_enforcer] {}", reason);

            if let Err(e) = self
                .execute_action(&self.config.default_action, &reason)
                .await
            {
                warn!("[docker_enforcer] Action failed: {}", e);
            }
        } else if mem_psi_high {
            let reason = format!(
                "Memory thrashing detected: psi_full={:.1}%",
                mem_psi_full
            );
            info!("[docker_enforcer] {}", reason);

            let action = self
                .config
                .rule_actions
                .get("oom_risk")
                .cloned()
                .unwrap_or_else(|| self.config.default_action.clone());

            if let Err(e) = self.execute_action(&action, &reason).await {
                warn!("[docker_enforcer] Action failed: {}", e);
            }
        }
    }
}

#[async_trait]
impl Handler for DockerEnforcer {
    fn name(&self) -> &'static str {
        "docker_enforcer"
    }

    async fn on_event(&self, event: &ProcessEvent) {
        // Events are handled via rule engine alerts, not individual events
        // This prevents action spam on every fork/exec
        let _ = event; // Suppress unused warning
    }

    async fn on_snapshot(&self, snapshot: &SystemSnapshot) {
        // Check PSI-based circuit breaker conditions
        self.check_snapshot_conditions(snapshot).await;
    }
}

fn action_verb(action: &ContainerAction) -> &'static str {
    match action {
        ContainerAction::Pause => "pause",
        ContainerAction::Stop => "stop",
        ContainerAction::Kill => "kill",
        ContainerAction::Restart => "restart",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_history_respects_cooldown() {
        let mut history = ActionHistory::new();

        // First action should be allowed
        assert!(history.can_take_action(Duration::from_secs(60), 10));
        history.record_action();

        // Second action within cooldown should be blocked
        assert!(!history.can_take_action(Duration::from_secs(60), 10));
    }

    #[test]
    fn action_history_respects_rate_limit() {
        let mut history = ActionHistory::new();

        // Fill up to rate limit
        for _ in 0..5 {
            assert!(history.can_take_action(Duration::from_secs(0), 5));
            history.record_action();
        }

        // Next action should be blocked
        assert!(!history.can_take_action(Duration::from_secs(0), 5));
    }

    #[test]
    fn matches_trigger_patterns() {
        let config = DockerEnforcementConfig {
            enabled: true,
            default_action: ContainerAction::Pause,
            target_container: "test".to_string(),
            trigger_patterns: vec!["fork_storm".to_string(), "oom_risk".to_string()],
            grace_period_secs: 5,
            cooldown_secs: 60,
            max_actions_per_hour: 10,
            rule_actions: HashMap::new(),
        };

        let enforcer = DockerEnforcer::new(config);

        assert!(enforcer.matches_trigger("fork_storm_demo"));
        assert!(enforcer.matches_trigger("oom_risk_detector"));
        assert!(!enforcer.matches_trigger("cpu_leak"));
    }

    #[test]
    fn rule_specific_actions() {
        let mut rule_actions = HashMap::new();
        rule_actions.insert("fork_storm".to_string(), ContainerAction::Pause);
        rule_actions.insert("oom_risk".to_string(), ContainerAction::Kill);

        let config = DockerEnforcementConfig {
            enabled: true,
            default_action: ContainerAction::Stop,
            target_container: "test".to_string(),
            trigger_patterns: Vec::new(),
            grace_period_secs: 5,
            cooldown_secs: 60,
            max_actions_per_hour: 10,
            rule_actions,
        };

        let enforcer = DockerEnforcer::new(config);

        assert_eq!(enforcer.get_action("fork_storm"), ContainerAction::Pause);
        assert_eq!(enforcer.get_action("oom_risk"), ContainerAction::Kill);
        assert_eq!(enforcer.get_action("other_rule"), ContainerAction::Stop);
    }
}
