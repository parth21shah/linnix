// eBPF-based DDoS protection
use anyhow::Result;
use dashmap::DashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct DDoSShield {
    /// Track request rates per IP
    ip_requests: Arc<DashMap<IpAddr, RequestTracker>>,
    /// Requests per second threshold
    rate_limit: u32,
    /// Ban duration
    ban_duration: Duration,
}

struct RequestTracker {
    count: u32,
    window_start: Instant,
    banned_until: Option<Instant>,
}

impl DDoSShield {
    pub fn new(rate_limit: u32, ban_minutes: u64) -> Self {
        Self {
            ip_requests: Arc::new(DashMap::new()),
            rate_limit,
            ban_duration: Duration::from_secs(ban_minutes * 60),
        }
    }

    /// Check if IP is currently banned
    pub fn is_banned(&self, ip: IpAddr) -> bool {
        if let Some(tracker) = self.ip_requests.get(&ip) {
            if let Some(banned_until) = tracker.banned_until {
                return Instant::now() < banned_until;
            }
        }
        false
    }

    /// Record a request from an IP
    pub fn record_request(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let mut tracker = self.ip_requests.entry(ip).or_insert(RequestTracker {
            count: 0,
            window_start: now,
            banned_until: None,
        });

        // Reset window if it's been more than 1 second
        if tracker.window_start.elapsed() > Duration::from_secs(1) {
            tracker.count = 1;
            tracker.window_start = now;
            return true;
        }

        tracker.count += 1;

        // Check if rate limit exceeded
        if tracker.count > self.rate_limit {
            log::warn!("🚨 DDoS detected from {} ({} req/s) - BANNING", ip, tracker.count);
            tracker.banned_until = Some(now + self.ban_duration);
            return false;
        }

        true
    }

    /// Ban an IP using iptables
    pub async fn ban_ip(&self, ip: IpAddr) -> Result<()> {
        let ip_str = ip.to_string();
        
        // Add iptables DROP rule
        let output = tokio::process::Command::new("iptables")
            .args(&[
                "-I", "INPUT",
                "-s", &ip_str,
                "-j", "DROP",
                "-m", "comment",
                "--comment", &format!("linnix-ddos-ban-{}", chrono::Utc::now().timestamp()),
            ])
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "Failed to ban IP {}: {}",
                ip,
                String::from_utf8_lossy(&output.stderr)
            );
        }

        log::info!("🛡️  Banned IP {} via iptables", ip);

        // Schedule unban
        let ip_requests = Arc::clone(&self.ip_requests);
        let ban_duration = self.ban_duration;
        tokio::spawn(async move {
            tokio::time::sleep(ban_duration).await;
            
            // Unban via iptables
            let ip_str = ip.to_string();
            let output = tokio::process::Command::new("iptables")
                .args(&["-D", "INPUT", "-s", &ip_str, "-j", "DROP"])
                .output()
                .await;
            
            match output {
                Ok(out) if out.status.success() => {
                    log::info!("✅ Unbanned IP {}", ip);
                    ip_requests.remove(&ip);
                }
                Ok(out) => {
                    log::error!("Failed to unban IP {}: {}", ip, String::from_utf8_lossy(&out.stderr));
                }
                Err(e) => {
                    log::error!("Failed to unban IP {}: {}", ip, e);
                }
            }
        });

        Ok(())
    }

    /// Unban an IP manually
    pub async fn unban_ip(&self, ip: IpAddr) -> Result<()> {
        let ip_str = ip.to_string();
        
        // Remove iptables rule
        let output = tokio::process::Command::new("iptables")
            .args(&[
                "-D", "INPUT",
                "-s", &ip_str,
                "-j", "DROP",
            ])
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "Failed to unban IP {}: {}",
                ip,
                String::from_utf8_lossy(&output.stderr)
            );
        }

        log::info!("✅ Unbanned IP {}", ip);
        self.ip_requests.remove(&ip);
        Ok(())
    }

    /// Cleanup old entries (run periodically)
    pub fn cleanup(&self) {
        let now = Instant::now();
        self.ip_requests.retain(|_, tracker| {
            // Remove entries older than 5 minutes
            tracker.window_start.elapsed() < Duration::from_secs(300)
        });
    }
}

/// Extract source IP from network packet metadata
/// (This would integrate with eBPF network probes)
pub fn extract_source_ip(/* eBPF packet data */) -> Option<IpAddr> {
    // TODO: Implement eBPF network probe to capture packet headers
    // For now, we can parse from nginx logs or use existing network monitoring
    None
}
