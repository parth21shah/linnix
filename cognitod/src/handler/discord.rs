// Stream Docker logs to Discord on errors
use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::VecDeque;

#[derive(Debug, Serialize)]
struct DiscordWebhookMessage {
    content: Option<String>,
    embeds: Vec<DiscordEmbed>,
}

#[derive(Debug, Serialize)]
struct DiscordEmbed {
    title: String,
    description: String,
    color: u32,
    timestamp: String,
    fields: Vec<DiscordField>,
}

#[derive(Debug, Serialize)]
struct DiscordField {
    name: String,
    value: String,
    inline: bool,
}

pub struct DiscordStreamer {
    webhook_url: String,
    client: reqwest::Client,
    /// Keep last N log lines per container
    log_buffers: dashmap::DashMap<String, VecDeque<String>>,
    buffer_size: usize,
}

impl DiscordStreamer {
    pub fn new(webhook_url: String, buffer_size: usize) -> Self {
        Self {
            webhook_url,
            client: reqwest::Client::new(),
            log_buffers: dashmap::DashMap::new(),
            buffer_size,
        }
    }

    /// Add a log line to the buffer
    pub fn add_log_line(&self, container_id: &str, line: String) {
        let mut buffer = self
            .log_buffers
            .entry(container_id.to_string())
            .or_insert_with(|| VecDeque::with_capacity(self.buffer_size));

        if buffer.len() >= self.buffer_size {
            buffer.pop_front();
        }
        buffer.push_back(line);
    }

    /// Check if log line contains an error
    pub fn is_error_line(line: &str) -> bool {
        let lower = line.to_lowercase();
        lower.contains("error")
            || lower.contains("panic")
            || lower.contains("exception")
            || lower.contains("fatal")
            || lower.contains("failed")
            || lower.contains("crash")
    }

    /// Send error alert to Discord
    pub async fn send_error_alert(
        &self,
        container_id: &str,
        container_name: &str,
        error_line: &str,
    ) -> Result<()> {
        // Get last 10 lines of context
        let context_lines = if let Some(buffer) = self.log_buffers.get(container_id) {
            buffer
                .iter()
                .rev()
                .take(10)
                .rev()
                .cloned()
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            error_line.to_string()
        };

        let message = DiscordWebhookMessage {
            content: Some(format!("🚨 **Error detected in {}**", container_name)),
            embeds: vec![DiscordEmbed {
                title: "Container Error".to_string(),
                description: format!("```\n{}\n```", context_lines),
                color: 0xFF0000, // Red
                timestamp: chrono::Utc::now().to_rfc3339(),
                fields: vec![
                    DiscordField {
                        name: "Container".to_string(),
                        value: container_name.to_string(),
                        inline: true,
                    },
                    DiscordField {
                        name: "Container ID".to_string(),
                        value: container_id[..12].to_string(), // First 12 chars
                        inline: true,
                    },
                    DiscordField {
                        name: "Error Line".to_string(),
                        value: format!("```{}```", error_line),
                        inline: false,
                    },
                ],
            }],
        };

        let response = self
            .client
            .post(&self.webhook_url)
            .json(&message)
            .send()
            .await
            .context("Failed to send Discord webhook")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("Discord webhook failed {}: {}", status, body);
        }

        log::info!("✅ Sent error alert to Discord for {}", container_name);
        Ok(())
    }

    /// Watch Docker logs and stream errors
    pub async fn watch_container_logs(
        &self,
        container_id: String,
        container_name: String,
    ) -> Result<()> {
        let mut child = tokio::process::Command::new("docker")
            .args(&["logs", "-f", &container_id])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .context("Failed to start docker logs")?;

        let stdout = child.stdout.take().context("Failed to get stdout")?;
        let stderr = child.stderr.take().context("Failed to get stderr")?;

        let streamer = self.clone();
        let cid = container_id.clone();
        let cname = container_name.clone();

        // Process stdout
        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut reader = BufReader::new(stdout).lines();

            while let Ok(Some(line)) = reader.next_line().await {
                streamer.add_log_line(&cid, line.clone());

                if Self::is_error_line(&line) {
                    if let Err(e) = streamer.send_error_alert(&cid, &cname, &line).await {
                        log::error!("Failed to send Discord alert: {}", e);
                    }
                }
            }
        });

        // Process stderr (errors usually go here)
        let streamer = self.clone();
        let cid = container_id.clone();
        let cname = container_name.clone();

        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut reader = BufReader::new(stderr).lines();

            while let Ok(Some(line)) = reader.next_line().await {
                streamer.add_log_line(&cid, line.clone());

                // stderr is more likely to have errors
                if Self::is_error_line(&line) || !line.is_empty() {
                    if let Err(e) = streamer.send_error_alert(&cid, &cname, &line).await {
                        log::error!("Failed to send Discord alert: {}", e);
                    }
                }
            }
        });

        Ok(())
    }

    fn clone(&self) -> Self {
        Self {
            webhook_url: self.webhook_url.clone(),
            client: self.client.clone(),
            log_buffers: self.log_buffers.clone(),
            buffer_size: self.buffer_size,
        }
    }
}
