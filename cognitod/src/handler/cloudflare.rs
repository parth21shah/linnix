// Cloudflare cache purge on deployment
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
struct CloudflarePurgeRequest {
    files: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct CloudflarePurgeResponse {
    success: bool,
    errors: Vec<serde_json::Value>,
}

pub struct CloudflareSync {
    api_token: String,
    zone_id: String,
    client: reqwest::Client,
}

impl CloudflareSync {
    pub fn new(api_token: String, zone_id: String) -> Self {
        Self {
            api_token,
            zone_id,
            client: reqwest::Client::new(),
        }
    }

    /// Purge entire zone cache (use after deployment)
    pub async fn purge_everything(&self) -> Result<()> {
        let url = format!(
            "https://api.cloudflare.com/client/v4/zones/{}/purge_cache",
            self.zone_id
        );

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .json(&serde_json::json!({"purge_everything": true}))
            .send()
            .await
            .context("Failed to send Cloudflare purge request")?;

        let result: CloudflarePurgeResponse = response
            .json()
            .await
            .context("Failed to parse Cloudflare response")?;

        if !result.success {
            anyhow::bail!("Cloudflare purge failed: {:?}", result.errors);
        }

        log::info!("✅ Cloudflare cache purged successfully");
        Ok(())
    }

    /// Purge specific URLs (use for partial updates)
    pub async fn purge_urls(&self, urls: Vec<String>) -> Result<()> {
        let url = format!(
            "https://api.cloudflare.com/client/v4/zones/{}/purge_cache",
            self.zone_id
        );

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .json(&CloudflarePurgeRequest { files: urls })
            .send()
            .await
            .context("Failed to send Cloudflare purge request")?;

        let result: CloudflarePurgeResponse = response
            .json()
            .await
            .context("Failed to parse Cloudflare response")?;

        if !result.success {
            anyhow::bail!("Cloudflare purge failed: {:?}", result.errors);
        }

        log::info!("✅ Cloudflare URLs purged successfully");
        Ok(())
    }
}

/// Detect Coolify deployment events by watching Docker container creations
pub fn is_deployment_event(comm: &str, cmdline: &str) -> bool {
    // Coolify creates containers with specific naming patterns
    comm == "docker" && (cmdline.contains("create") || cmdline.contains("start"))
        && (cmdline.contains("coolify") || cmdline.contains("deployment"))
}
