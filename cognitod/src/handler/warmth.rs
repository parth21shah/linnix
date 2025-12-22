// Keep containers warm - prevent cold starts
use anyhow::Result;
use dashmap::DashMap;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::time::sleep;

pub struct WarmthKeeper {
    /// Track last activity per container
    last_activity: Arc<DashMap<String, Instant>>,
    /// HTTP client for health checks
    client: reqwest::Client,
    /// Idle threshold before we start warming
    idle_threshold: Duration,
    /// Ping interval for warmth checks
    ping_interval: Duration,
    /// Container ID -> health URL mapping
    container_urls: HashMap<String, String>,
}

impl WarmthKeeper {
    pub fn new(
        idle_threshold_secs: u64,
        ping_interval_secs: u64,
        containers: Vec<crate::config::ContainerConfig>,
    ) -> Self {
        // Build container URL map
        let mut container_urls = HashMap::new();
        for container in containers {
            if let Some(url) = container.warmth_url {
                container_urls.insert(container.name.clone(), url);
            }
        }

        Self {
            last_activity: Arc::new(DashMap::new()),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
            idle_threshold: Duration::from_secs(idle_threshold_secs),
            ping_interval: Duration::from_secs(ping_interval_secs),
            container_urls,
        }
    }

    /// Record activity for a container
    pub fn record_activity(&self, container_id: &str) {
        self.last_activity.insert(container_id.to_string(), Instant::now());
    }

    /// Check if container needs warming
    pub fn needs_warming(&self, container_id: &str) -> bool {
        if let Some(last) = self.last_activity.get(container_id) {
            last.elapsed() > self.idle_threshold
        } else {
            false
        }
    }

    /// Start warmth keeper for all configured containers
    pub fn start(&self) {
        for (container_name, health_url) in &self.container_urls {
            log::info!("Starting warmth keeper for container '{}' -> {}", container_name, health_url);
            self.start_warming(container_name.clone(), health_url.clone());
        }
    }

    /// Start warmth keeper loop for a container
    fn start_warming(&self, container_id: String, health_url: String) {
        let client = self.client.clone();
        let last_activity = Arc::clone(&self.last_activity);
        let idle_threshold = self.idle_threshold;
        let ping_interval = self.ping_interval;

        tokio::spawn(async move {
            loop {
                sleep(ping_interval).await;

                // Check if container has been idle
                let should_ping = if let Some(last) = last_activity.get(&container_id) {
                    last.elapsed() > idle_threshold
                } else {
                    // No activity recorded yet, assume it needs warming
                    true
                };

                if should_ping {
                    log::debug!("Warming container '{}' via {}", container_id, health_url);
                    
                    match client.get(&health_url).send().await {
                        Ok(resp) if resp.status().is_success() => {
                            log::trace!("Container '{}' warm ({})", container_id, resp.status());
                        }
                        Ok(resp) => {
                            log::warn!("Container '{}' warmth check failed: {}", container_id, resp.status());
                        }
                        Err(e) => {
                            log::warn!("Container '{}' warmth check error: {}", container_id, e);
                        }
                    }
                }
            }
        });
    }

    /// Detect container activity from eBPF events
    pub fn process_event(&self, pid: u32, comm: &str, container_id: Option<&str>) {
        // If this process belongs to a container, record activity
        if let Some(cid) = container_id {
            // Skip our own health checks
            if comm != "curl" && comm != "wget" {
                self.record_activity(cid);
            }
        }
    }
}

/// Extract container ID from cgroup path
pub fn extract_container_id(cgroup: &str) -> Option<String> {
    // Example: /docker/abc123def456...
    if let Some(stripped) = cgroup.strip_prefix("/docker/") {
        Some(stripped.split('/').next()?.to_string())
    } else {
        None
    }
}
