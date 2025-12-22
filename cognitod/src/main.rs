// let_chains stabilized in Rust 1.82 (Jan 2025)
// Both local stable and Docker stable support it without feature flags

// Removed redundant import of ContextStore
use anyhow::Context;
use aya::Pod;
use aya::maps::{
    MapData,
    perf::{PerfEventArray, PerfEventArrayBuffer},
};
use aya::programs::{KProbe, TracePoint};
use aya::util::online_cpus;
use aya::{Ebpf, EbpfLoader};
use aya_log::EbpfLogger;
use caps::{CapSet, Capability};
use log::{info, warn};
use std::{convert::TryFrom, error::Error, path::PathBuf, sync::Arc, time::Duration};
use tokio::fs::OpenOptions;
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::sync::broadcast;
use tokio::time::{sleep, timeout};

use crate::insights::InsightStore;
use crate::runtime::start_perf_listener;
pub use linnix_ai_ebpf_common::PERCENT_MILLI_UNKNOWN;
pub use linnix_ai_ebpf_common::ProcessEvent as ProcessEventWire;
pub use linnix_ai_ebpf_common::ProcessEventExt as ProcessEvent;
use linnix_ai_ebpf_common::TelemetryConfig;

mod api;
mod runtime;
// mod routes; // Deleted (dead code cleanup)

use cognitod::bpf_config;
use cognitod::config;
use cognitod::context;
use cognitod::enforcement;
use cognitod::handler;
use cognitod::insights;
use cognitod::metrics;
use cognitod::types;
use cognitod::ui;

#[repr(transparent)]
#[derive(Copy, Clone)]
struct TelemetryConfigPod(TelemetryConfig);

unsafe impl Pod for TelemetryConfigPod {}

struct BpfRuntimeGuards {
    _bpf: Ebpf,
    _logger: Option<EbpfLogger>,
}

const INSIGHT_STORE_CAPACITY: usize = 50;

fn attach_kprobe_internal(bpf: &mut Ebpf, program: &str, symbol: &str) -> anyhow::Result<()> {
    let probe: &mut KProbe = bpf
        .program_mut(program)
        .ok_or_else(|| anyhow::anyhow!("{program} program not found"))?
        .try_into()?;
    probe.load()?;
    probe.attach(symbol, 0)?;
    Ok(())
}

fn attach_kprobe_optional(bpf: &mut Ebpf, program: &str, symbol: &str) {
    if let Err(err) = attach_kprobe_internal(bpf, program, symbol) {
        warn!("[cognitod] optional kprobe {symbol} ({program}) not attached: {err:?}");
    }
}

fn attach_tracepoint_internal(
    bpf: &mut Ebpf,
    program: &str,
    category: &str,
    name: &str,
) -> anyhow::Result<()> {
    let tp: &mut TracePoint = bpf
        .program_mut(program)
        .ok_or_else(|| anyhow::anyhow!("{program} program not found"))?
        .try_into()?;
    tp.load()?;
    tp.attach(category, name)?;
    Ok(())
}

fn attach_tracepoint_optional(bpf: &mut Ebpf, program: &str, category: &str, name: &str) {
    if let Err(err) = attach_tracepoint_internal(bpf, program, category, name) {
        warn!("[cognitod] optional tracepoint {category}:{name} ({program}) not attached: {err:?}");
    }
}

use crate::api::{AppState, all_routes};
use crate::bpf_config::{CoreRssMode, derive_telemetry_config};
use crate::runtime::probes::{ProbeState, RssProbeMode};
use clap::Parser;
use cognitod::alerts::RuleEngine;
use cognitod::config::{Config, OfflineGuard};
use cognitod::handler::{HandlerList, JsonlHandler};
use cognitod::metrics::Metrics;
use serde_json::json;
use std::{fs, path::Path};

/// Spawn background tasks for metrics collection and logging.
fn spawn_metrics_tasks(metrics: Arc<Metrics>) {
    // Roll up events/s every second
    {
        let metrics_clone = Arc::clone(&metrics);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                metrics_clone.rollup();
            }
        });
    }

    // Log metrics summary every 10 seconds
    {
        let metrics_clone = Arc::clone(&metrics);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(10));
            loop {
                interval.tick().await;
                log::debug!(
                    "metrics: events/s={} rb_overflows={} rate_limited={}",
                    metrics_clone.events_per_sec(),
                    metrics_clone.rb_overflows(),
                    metrics_clone.rate_limited_events()
                );
            }
        });
    }
}

#[derive(Parser, Debug)]
#[command(name = "cognitod")]
#[command(about = "Linnix Cognition Daemon")]
struct Args {
    /// Path to config file
    #[arg(long, value_name = "PATH", default_value = "/etc/linnix/linnix.toml")]
    config: PathBuf,
    #[arg(long)]
    handler: Vec<String>,
    #[arg(long)]
    detach: bool,
    #[arg(long)]
    dry_run: bool,
    #[arg(long)]
    probe_only: bool,
}

/// Generate search paths for BPF objects in canonical order:
/// 1. Installed location (/usr/local/share/linnix/)
/// 2. Release build (target/bpfel-unknown-none/release/)
/// 3. Legacy build (target/bpf/)
///
/// Each with relative path variants (., .., ../..) for development flexibility.
fn bpf_search_paths(base_name: &str) -> Vec<String> {
    let mut paths = Vec::new();

    // Canonical install location (production)
    paths.push(format!("/usr/local/share/linnix/{}", base_name));
    paths.push(format!("/usr/local/share/linnix/{}.o", base_name));

    // Development build paths (release target)
    for prefix in &["target", "./target", "../target", "../../target"] {
        paths.push(format!(
            "{}/bpfel-unknown-none/release/{}",
            prefix, base_name
        ));
    }

    // Legacy build paths (kept for backward compatibility)
    for prefix in &["target", "./target", "../target", "../../target"] {
        paths.push(format!("{}/bpf/{}.o", prefix, base_name));
    }

    paths
}

/// Locate and read an eBPF object with clear precedence:
/// 1. Environment variable (if provided) - overrides all
/// 2. Generated search paths - canonical install → dev builds → legacy
fn read_bpf_object(env_var: &str, base_name: &str) -> anyhow::Result<(Vec<u8>, String)> {
    // Priority 1: Environment variable override
    if let Ok(path) = std::env::var(env_var) {
        let data = fs::read(&path)
            .with_context(|| format!("{} points to {}, but failed to read", env_var, path))?;
        return Ok((data, path));
    }

    // Priority 2: Search canonical locations
    let candidates = bpf_search_paths(base_name);
    for candidate in &candidates {
        if Path::new(candidate).exists() {
            return Ok((fs::read(candidate)?, candidate.to_string()));
        }
    }

    // Not found - provide helpful error with search locations
    anyhow::bail!(
        "BPF object '{}' not found. Searched:\n  {}\n\nSet {} to specify custom location, or install to /usr/local/share/linnix/",
        base_name,
        candidates.join("\n  "),
        env_var
    )
}

/// Locate and read the primary eBPF object.
fn read_bpf_bytes() -> anyhow::Result<(Vec<u8>, String)> {
    read_bpf_object("LINNIX_BPF_PATH", "linnix-ai-ebpf-ebpf")
}

/// Locate and read the rss_trace fallback object.
fn read_rss_trace_bytes() -> anyhow::Result<(Vec<u8>, String)> {
    read_bpf_object("LINNIX_RSS_TRACE_BPF_PATH", "rss_trace")
}

fn init_ebpf(
    bpf_bytes: &[u8],
    telemetry_cfg: TelemetryConfig,
) -> anyhow::Result<(BpfRuntimeGuards, Vec<PerfEventArrayBuffer<MapData>>)> {
    let telemetry = TelemetryConfigPod(telemetry_cfg);
    let mut loader = EbpfLoader::new();
    loader.set_global("TELEMETRY_CONFIG", &telemetry, true);
    let mut bpf = loader.load(bpf_bytes)?;

    let logger = match EbpfLogger::init(&mut bpf) {
        Ok(logger) => {
            info!("[cognitod] BPF logger initialized.");
            Some(logger)
        }
        Err(e) => {
            warn!("[cognitod] BPF logger not active: {e}");
            None
        }
    };

    attach_tracepoint_internal(&mut bpf, "linnix_ai_ebpf", "sched", "sched_process_exec")?;

    attach_tracepoint_internal(&mut bpf, "handle_fork", "sched", "sched_process_fork").map_err(
        |e| {
            eprintln!("Failed to attach fork program: {e}");
            e
        },
    )?;
    println!("[cognitod] Fork program loaded and attached.");
    info!("[cognitod] Fork program attached.");

    attach_tracepoint_internal(&mut bpf, "handle_exit", "sched", "sched_process_exit")?;

    attach_kprobe_internal(&mut bpf, "trace_tcp_send", "tcp_sendmsg")?;
    attach_kprobe_internal(&mut bpf, "trace_tcp_recv", "tcp_recvmsg")?;
    attach_kprobe_internal(&mut bpf, "trace_vfs_read", "vfs_read")?;
    attach_kprobe_internal(&mut bpf, "trace_vfs_write", "vfs_write")?;

    attach_kprobe_optional(&mut bpf, "trace_udp_send", "udp_sendmsg");
    attach_kprobe_optional(&mut bpf, "trace_udp_recv", "udp_recvmsg");
    attach_kprobe_optional(&mut bpf, "trace_unix_stream_send", "unix_stream_sendmsg");
    attach_kprobe_optional(&mut bpf, "trace_unix_stream_recv", "unix_stream_recvmsg");
    attach_kprobe_optional(&mut bpf, "trace_unix_dgram_send", "unix_dgram_sendmsg");
    attach_kprobe_optional(&mut bpf, "trace_unix_dgram_recv", "unix_dgram_recvmsg");

    attach_tracepoint_internal(&mut bpf, "trace_sys_enter", "raw_syscalls", "sys_enter")?;

    attach_tracepoint_optional(&mut bpf, "trace_block_queue", "block", "block_bio_queue");
    attach_tracepoint_optional(&mut bpf, "trace_block_issue", "block", "block_rq_issue");
    attach_tracepoint_optional(
        &mut bpf,
        "trace_block_complete",
        "block",
        "block_rq_complete",
    );

    info!("[cognitod] Program attached. Setting up perf buffers...");

    let events_map = bpf
        .take_map("EVENTS")
        .ok_or_else(|| anyhow::anyhow!("EVENTS map not found"))?;
    let mut perf_array = PerfEventArray::try_from(events_map)?;
    let mut perf_buffers = Vec::new();
    for cpu in online_cpus().map_err(|(_, e)| e)? {
        perf_buffers.push(perf_array.open(cpu, None)?);
    }

    Ok((
        BpfRuntimeGuards {
            _bpf: bpf,
            _logger: logger,
        },
        perf_buffers,
    ))
}

fn init_rss_trace(bpf_bytes: &[u8]) -> anyhow::Result<BpfRuntimeGuards> {
    let mut loader = EbpfLoader::new();
    let mut bpf = loader.load(bpf_bytes)?;

    let logger = match EbpfLogger::init(&mut bpf) {
        Ok(logger) => {
            info!("[cognitod] BPF logger initialized for tracepoint fallback.");
            Some(logger)
        }
        Err(e) => {
            warn!("[cognitod] Tracepoint fallback logger not active: {e}");
            None
        }
    };

    attach_tracepoint_internal(&mut bpf, "trace_rss_stat", "mm", "rss_stat")?;

    Ok(BpfRuntimeGuards {
        _bpf: bpf,
        _logger: logger,
    })
}

fn check_capabilities() -> anyhow::Result<()> {
    if std::env::var("LINNIX_SKIP_CAP_CHECK").is_ok() {
        warn!("Skipping capability check (LINNIX_SKIP_CAP_CHECK set)");
        return Ok(());
    }

    let has_bpf = caps::has_cap(None, CapSet::Effective, Capability::CAP_BPF)
        .context("failed to query CAP_BPF")?;
    let has_perfmon = caps::has_cap(None, CapSet::Effective, Capability::CAP_PERFMON)
        .context("failed to query CAP_PERFMON")?;

    if has_bpf && has_perfmon {
        info!("Running with CAP_BPF + CAP_PERFMON");
        return Ok(());
    }

    // Missing required capabilities
    eprintln!("\nERROR: Missing required capabilities CAP_BPF and CAP_PERFMON");
    eprintln!("\nFix:");
    eprintln!("  sudo setcap cap_bpf,cap_perfmon=ep $(which cognitod)");
    eprintln!("\nOr use Docker:");
    eprintln!(
        "  docker run --cap-add=BPF --cap-add=PERFMON --cap-drop=ALL ghcr.io/linnix-os/cognitod:latest"
    );
    eprintln!("\nRequires: Linux 5.8+ with BTF support (/sys/kernel/btf/vmlinux)");
    eprintln!("Docs: https://docs.linnix.io/installation\n");

    anyhow::bail!("missing CAP_BPF and CAP_PERFMON")
}

fn check_kernel_version(min_major: u32, min_minor: u32) -> anyhow::Result<()> {
    let release = fs::read_to_string("/proc/sys/kernel/osrelease")
        .context("failed to read /proc/sys/kernel/osrelease")?;
    let version =
        parse_kernel_version(&release).context("unable to parse kernel release string")?;

    if version < (min_major, min_minor) {
        anyhow::bail!(
            "kernel {}.{} lacks required eBPF support (need >= {}.{})",
            version.0,
            version.1,
            min_major,
            min_minor
        );
    }
    Ok(())
}

fn ensure_environment() -> anyhow::Result<()> {
    check_capabilities()?;
    check_kernel_version(5, 8)?;
    Ok(())
}

fn parse_kernel_version(raw: &str) -> Option<(u32, u32)> {
    let version_part = raw.trim().split('-').next()?;
    let mut segments = version_part.split('.');
    let major = segments.next()?.parse().ok()?;
    let minor = segments.next().unwrap_or("0").parse().ok()?;
    Some((major, minor))
}

/// Extract cgroup context for a process to identify the Kubernetes pod/tenant.
/// Returns something like "kubepods-burstable-pod123abc" or "akash-deployment-xyz"
fn get_process_cgroup_context(pid: u32) -> Option<String> {
    let cgroup_path = format!("/proc/{}/cgroup", pid);
    let content = std::fs::read_to_string(&cgroup_path).ok()?;
    
    // Parse cgroup v2 or v1 format
    for line in content.lines() {
        // cgroup v2: "0::/kubepods.slice/kubepods-burstable.slice/..."
        // cgroup v1: "1:memory:/kubepods/burstable/pod..."
        let path = line.split(':').last()?;
        
        // Look for Kubernetes pod paths
        if path.contains("kubepods") || path.contains("docker") || path.contains("containerd") {
            // Extract meaningful portion
            let parts: Vec<&str> = path.split('/').collect();
            
            // Find pod UID or container ID
            for part in parts.iter().rev() {
                if part.starts_with("pod") || part.starts_with("cri-containerd") {
                    // Clean up the identifier
                    let clean = part
                        .replace("kubepods-", "")
                        .replace(".slice", "")
                        .replace("cri-containerd-", "")
                        .replace(".scope", "");
                    if clean.len() > 8 {
                        return Some(clean[..12.min(clean.len())].to_string());
                    }
                }
            }
            
            // Fallback: return last meaningful segment
            if let Some(last) = parts.iter().rev().find(|p| !p.is_empty() && p.len() > 5) {
                let clean = last.replace(".scope", "").replace(".slice", "");
                if clean.len() > 8 {
                    return Some(clean[..12.min(clean.len())].to_string());
                }
            }
        }
    }
    None
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();
    let args = Args::parse();
    let handler = args.handler.clone();
    let detach = args.detach;
    if detach {
        println!("[cognitod] Detaching eBPF programs...");
        // eBPF programs are not pinned, so dropping the process is enough.
        // This hook allows uninstall scripts to trigger any additional cleanup
        // if necessary.
        return Ok(());
    }
    println!("[cognitod] Starting Cognition Daemon...");

    ensure_environment()?;

    // Load configuration from CLI-specified path
    let config = Config::load_from(&args.config);
    let offline_guard = Arc::new(OfflineGuard::new(config.runtime.offline));

    // Initialize metrics and spawn background reporting tasks
    let metrics = Arc::new(Metrics::new());
    spawn_metrics_tasks(Arc::clone(&metrics));

    // --- Prepare kernel instrumentation with graceful fallback ---
    let mut perf_buffers: Vec<PerfEventArrayBuffer<MapData>> = Vec::new();
    let mut transport: &'static str = "userspace";
    let mut _bpf_runtime: Option<BpfRuntimeGuards> = None;
    let mut probe_state = ProbeState::disabled();

    let btf_path = std::env::var("LINNIX_KERNEL_BTF")
        .unwrap_or_else(|_| "/sys/kernel/btf/vmlinux".to_string());
    let btf_available = std::path::Path::new(&btf_path).is_file();
    let tracepoint_available =
        std::path::Path::new("/sys/kernel/tracing/events/mm/rss_stat").is_dir();
    let mut core_signal_ok = false;
    let mut core_mm_ok = false;

    if btf_available {
        match derive_telemetry_config() {
            Ok(result) => {
                core_signal_ok = result.signal_supported;
                core_mm_ok = result.mm_supported;
                let telemetry_cfg = result.config;
                let (bpf_bytes, chosen_path) = read_bpf_bytes()?;
                println!("[cognitod] Using BPF object: {chosen_path}");
                match init_ebpf(&bpf_bytes, telemetry_cfg) {
                    Ok((guards, buffers)) => {
                        transport = "perf";
                        perf_buffers = buffers;
                        _bpf_runtime = Some(guards);
                        probe_state = ProbeState {
                            rss_probe: match result.mode {
                                CoreRssMode::MmStruct => RssProbeMode::CoreMm,
                                CoreRssMode::SignalStruct => RssProbeMode::CoreSignal,
                            },
                            btf_available,
                        };
                    }
                    Err(err) => {
                        warn!(
                            "[cognitod] eBPF initialization failed ({err}); running without kernel instrumentation."
                        );
                    }
                }
            }
            Err(err) => {
                warn!(
                    "[cognitod] Unable to derive telemetry offsets from kernel BTF ({err}); running without kernel instrumentation."
                );
            }
        }
    }

    if matches!(probe_state.rss_probe, RssProbeMode::Disabled) && tracepoint_available {
        match read_rss_trace_bytes() {
            Ok((trace_bytes, chosen_path)) => {
                println!("[cognitod] Using tracepoint fallback object: {chosen_path}");
                match init_rss_trace(&trace_bytes) {
                    Ok(guards) => {
                        transport = "tracepoint";
                        _bpf_runtime = Some(guards);
                        probe_state.rss_probe = RssProbeMode::Tracepoint;
                        info!("[cognitod] Tracepoint fallback mm:rss_stat attached");
                    }
                    Err(err) => {
                        warn!(
                            "[cognitod] Failed to initialize rss tracepoint fallback ({err}); proceeding without RSS probe."
                        );
                    }
                }
            }
            Err(err) => {
                warn!(
                    "[cognitod] Unable to locate rss tracepoint BPF object ({err}); proceeding without RSS probe"
                );
            }
        }
    }

    probe_state.btf_available = btf_available;

    info!(
        "btf=vmlinux {}",
        if btf_available { "present" } else { "absent" }
    );
    info!(
        "core probe mm={} signal={}",
        if core_mm_ok { "ok" } else { "no" },
        if core_signal_ok { "ok" } else { "no" }
    );
    info!(
        "tracepoint {}",
        if tracepoint_available {
            "present"
        } else {
            "absent"
        }
    );
    info!("final rss mode = {}", probe_state.rss_probe.as_str());

    metrics.set_rss_probe_mode(probe_state.rss_probe.metric_value());
    metrics.set_kernel_btf_available(btf_available);

    if args.probe_only {
        let payload = json!({
            "rss_probe": probe_state.rss_probe.as_str(),
            "btf": probe_state.btf_available,
        });
        println!("{payload}");
        return Ok(());
    }

    if args.dry_run {
        println!("[cognitod] Dry run requested; exiting after probe setup.");
        return Ok(());
    }

    if perf_buffers.is_empty() && !matches!(probe_state.rss_probe, RssProbeMode::Tracepoint) {
        info!(
            "[cognitod] Kernel instrumentation disabled; Cognitod will continue in userspace-only mode."
        );
    }

    let k8s_context = cognitod::k8s::K8sContext::new();
    if let Some(ctx) = &k8s_context {
        info!(
            "[cognitod] K8s context initialized (node: {})",
            ctx.node_name
        );
        ctx.clone().start_watcher();
    } else {
        info!("[cognitod] K8s context not available (missing env/tokens)");
    }

    let context = Arc::new(context::ContextStore::new(
        Duration::from_secs(300),
        1000,
        k8s_context.clone(),
    ));
    let insight_store = {
        let path = config.logging.insights_file.trim();
        let path = if path.is_empty() {
            None
        } else {
            Some(PathBuf::from(path))
        };
        Arc::new(InsightStore::new(INSIGHT_STORE_CAPACITY, path))
    };

    // Initialize incident store for circuit breaker events
    let incident_db_path = std::env::var("LINNIX_INCIDENT_DB")
        .unwrap_or_else(|_| "/var/lib/linnix/incidents.db".to_string());

    let incident_db_path = std::path::Path::new(&incident_db_path)
        .canonicalize()
        .unwrap_or_else(|_| {
            if std::path::Path::new(&incident_db_path).is_absolute() {
                std::path::PathBuf::from(&incident_db_path)
            } else {
                std::env::current_dir()
                    .unwrap_or_default()
                    .join(&incident_db_path)
            }
        });

    let mut db_path_valid = true;
    if let Some(parent) = incident_db_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            warn!(
                "[cognitod] Failed to create incident DB directory {}: {}",
                parent.display(),
                e
            );
            db_path_valid = false;
        } else {
            let test_file = parent.join(".write_test");
            if let Err(e) = std::fs::write(&test_file, "") {
                warn!(
                    "[cognitod] Incident DB directory {} not writable: {}",
                    parent.display(),
                    e
                );
                db_path_valid = false;
            } else {
                let _ = std::fs::remove_file(&test_file);
            }
        }
    }

    let incident_store: Option<Arc<cognitod::IncidentStore>> = if db_path_valid {
        let db_path_str = incident_db_path.to_string_lossy().to_string();
        match cognitod::IncidentStore::new(&db_path_str).await {
            Ok(store) => {
                info!(
                    "[cognitod] Incident store initialized at {}",
                    incident_db_path.display()
                );
                Some(Arc::new(store))
            }
            Err(e) => {
                warn!("[cognitod] Failed to initialize incident store: {}", e);
                None
            }
        }
    } else {
        None
    };

    let incident_analyzer = if config.reasoner.enabled && !config.reasoner.endpoint.is_empty() {
        match cognitod::IncidentAnalyzer::new(
            config.reasoner.endpoint.clone(),
            Duration::from_millis(config.reasoner.timeout_ms),
        ) {
            Ok(analyzer) => {
                info!("[incident_analyzer] LLM analysis enabled for incidents");
                Some(Arc::new(analyzer))
            }
            Err(e) => {
                warn!("[incident_analyzer] Failed to initialize: {}", e);
                None
            }
        }
    } else {
        None
    };

    // Handlers specified on the command line
    let mut handler_list = HandlerList::new();
    let enforcement_queue = Some(Arc::new(enforcement::EnforcementQueue::new(300)));
    let mut alert_tx = None;
    for h in handler {
        if let Some(path) = h.strip_prefix("jsonl:") {
            if let Ok(hdl) = JsonlHandler::new(path).await {
                handler_list.register(hdl);
            }
        } else if let Some(path) = h.strip_prefix("rules:") {
            match RuleEngine::from_path(
                path,
                config.logging.alerts_file.clone(),
                config.logging.journald,
                Arc::clone(&metrics),
            ) {
                Ok(engine) => {
                    let rule_count = engine.rule_count();
                    let broadcaster = engine.broadcaster();
                    info!(
                        "[cognitod] Rules handler loaded from {} ({} rules)",
                        path, rule_count
                    );
                    metrics.add_active_rules(rule_count);
                    alert_tx = Some(broadcaster);
                    handler_list.register(engine);
                }
                Err(e) => warn!("[cognitod] failed to load rules from {}: {e}", path),
            }
        } else if h == "docker" || h.starts_with("docker:") {
            // Support both "docker" (uses config) and "docker:container_name" (CLI override)
            let docker_config = if let Some(container) = h.strip_prefix("docker:") {
                // CLI override
                Some(handler::docker::DockerEnforcementConfig {
                    enabled: true,
                    default_action: handler::docker::ContainerAction::Pause,
                    target_container: container.to_string(),
                    trigger_patterns: vec![
                        "fork_storm".to_string(),
                        "oom_risk".to_string(),
                        "cpu_spin".to_string(),
                    ],
                    grace_period_secs: 5,
                    cooldown_secs: 60,
                    max_actions_per_hour: 10,
                    rule_actions: std::collections::HashMap::new(),
                })
            } else {
                // Use config
                config.docker_enforcement.clone()
            };

            if let Some(docker_cfg) = docker_config {
                let enforcer = handler::docker::DockerEnforcer::new(docker_cfg);
                handler_list.register(enforcer);
                info!("[cognitod] Docker enforcement handler registered");
            } else {
                warn!("[cognitod] Docker handler requested but not configured");
            }
        }
    }

    // Load rules engine from config if not specified via CLI
    if alert_tx.is_none() {
        let rules_path = &config.rules.path;
        match RuleEngine::from_path(
            rules_path,
            config.logging.alerts_file.clone(),
            config.logging.journald,
            Arc::clone(&metrics),
        ) {
            Ok(engine) => {
                let rule_count = engine.rule_count();
                let broadcaster = engine.broadcaster();
                info!(
                    "[cognitod] Rules handler loaded from config {} ({} rules)",
                    rules_path, rule_count
                );
                metrics.add_active_rules(rule_count);
                alert_tx = Some(broadcaster);
                handler_list.register(engine);
            }
            Err(e) => warn!(
                "[cognitod] rules engine unavailable; failed to load {}: {e}",
                rules_path
            ),
        }
    }

    // Load docker enforcement from config if present
    if let Some(docker_cfg) = config.docker_enforcement.clone() {
        if docker_cfg.enabled {
            let enforcer = handler::docker::DockerEnforcer::new(docker_cfg);
            handler_list.register(enforcer);
            info!("[cognitod] Docker enforcement handler loaded from config");
        }
    }

    if let Some(path) = config.logging.incident_context_file.clone() {
        if let Some(sender) = alert_tx.clone() {
            let mut rx = sender.subscribe();
            let log_path = PathBuf::from(path);
            tokio::spawn(async move {
                if let Some(parent) = log_path.parent()
                    && let Err(err) = tokio::fs::create_dir_all(parent).await
                {
                    warn!(
                        "[cognitod] failed to create incident log directory {:?}: {}",
                        parent, err
                    );
                    return;
                }
                let file = match OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .await
                {
                    Ok(f) => f,
                    Err(err) => {
                        warn!(
                            "[cognitod] failed to open incident context log {}: {}",
                            log_path.display(),
                            err
                        );
                        return;
                    }
                };
                let mut writer = BufWriter::new(file);
                loop {
                    match rx.recv().await {
                        Ok(alert) => {
                            let line = alert.incident_context_line();
                            if let Err(err) = writer.write_all(line.as_bytes()).await {
                                warn!(
                                    "[cognitod] incident log write failed ({}): {}",
                                    log_path.display(),
                                    err
                                );
                                break;
                            }
                            if let Err(err) = writer.write_all(b"\n").await {
                                warn!(
                                    "[cognitod] incident log newline write failed ({}): {}",
                                    log_path.display(),
                                    err
                                );
                                break;
                            }
                            if let Err(err) = writer.flush().await {
                                warn!(
                                    "[cognitod] incident log flush failed ({}): {}",
                                    log_path.display(),
                                    err
                                );
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        } else {
            warn!("[cognitod] incident context logging requested but no alert handler is active");
        }
    }

    // Spawn Apprise notifier if configured
    if let Some(ref notif_config) = config.notifications
        && let Some(ref apprise_config) = notif_config.apprise
    {
        if let Some(alert_tx) = &alert_tx {
            let apprise_rx = alert_tx.subscribe();
            let url_count = apprise_config.urls.len();

            let apprise_config_owned = apprise_config.clone();
            tokio::spawn(async move {
                let notifier =
                    cognitod::notifications::AppriseNotifier::new(apprise_config_owned, apprise_rx);
                notifier.run().await;
            });

            info!(
                "[cognitod] Apprise notifier started with {} URL(s)",
                url_count
            );
        } else {
            warn!("[cognitod] Apprise notifications requested but no alert handler is active");
        }
    }

    // KB Index removed (YAGNI cleanup)

    // Start PSI monitor (after incident store is ready)
    if let Some(ctx) = &k8s_context {
        let psi_monitor = cognitod::collectors::psi::PsiMonitor::new(
            ctx.clone(),
            context.clone(),
            incident_store.clone(),
            config.psi.sustained_pressure_seconds,
        );
        tokio::spawn(async move {
            psi_monitor.run().await;
        });
    }

    // Initialize Slack Notifier
    let _slack_notifier = if let Some(ref notif_cfg) = config.notifications {
        if let Some(ref slack_cfg) = notif_cfg.slack {
            if let Some(ref tx) = alert_tx {
                // SlackNotifier workaround: create two instances because run() consumes self.
                // One for the alert loop, one for ILM insights (with dummy channel).
                let (_dummy_tx, dummy_rx) = tokio::sync::broadcast::channel(1);
                let notifier_ilm = Arc::new(cognitod::notifications::SlackNotifier::new(
                    slack_cfg.clone(),
                    dummy_rx,
                ));

                let notifier_alerts =
                    cognitod::notifications::SlackNotifier::new(slack_cfg.clone(), tx.subscribe());
                tokio::spawn(async move {
                    notifier_alerts.run().await;
                });

                Some(notifier_ilm)
            } else {
                // No alert_tx (e.g. rules disabled), but we might still want ILM insights to go to Slack.
                // We still need a dummy rx.
                let (_dummy_tx, dummy_rx) = tokio::sync::broadcast::channel(1);
                let notifier = Arc::new(cognitod::notifications::SlackNotifier::new(
                    slack_cfg.clone(),
                    dummy_rx,
                ));
                Some(notifier)
            }
        } else {
            None
        }
    } else {
        None
    };

    // LocalIlmHandlerRag removed (YAGNI cleanup)

    let handlers = Arc::new(handler_list);
    
    // Initialize Warmth Keeper (Pro feature)
    if config.warmth.enabled {
        let keeper = Arc::new(handler::warmth::WarmthKeeper::new(
            config.warmth.idle_threshold_secs,
            config.warmth.ping_interval_secs,
            config.containers.clone(),
        ));
        info!("[cognitod] Warmth Keeper enabled (idle={} ping={} containers={})",
            config.warmth.idle_threshold_secs,
            config.warmth.ping_interval_secs,
            config.containers.len()
        );
        keeper.start();
        
        // Store globally for event processing
        runtime::WARMTH_KEEPER.set(keeper).ok();
    }
    
    // Pass metrics to your listener
    if !perf_buffers.is_empty() {
        start_perf_listener(
            perf_buffers,
            Arc::clone(&context),
            Arc::clone(&metrics),
            Arc::clone(&handlers),
            Arc::clone(&offline_guard),
            config.runtime.events_rate_cap,
        );
    }

    // 🔁 Periodically refresh system snapshot (conditional on activity)
    let ctx_clone = Arc::clone(&context);
    let handlers_clone = Arc::clone(&handlers);
    let metrics_clone = Arc::clone(&metrics);
    // let reasoner_cfg = config.reasoner.clone(); // Unused
    tokio::spawn(async move {
        loop {
            // Only update when system is active (events/sec >= reasoner threshold)
            let eps = metrics_clone.events_per_sec();
            let is_active = eps >= 20; // Hardcoded default (YAGNI cleanup)

            // Always update system snapshot for dashboard
            ctx_clone.update_system_snapshot();

            if is_active {
                let snap = ctx_clone.get_system_snapshot();
                handlers_clone.on_snapshot(&snap).await;
            }

            sleep(Duration::from_secs(5)).await;
        }
    });

    // 🔁 Periodically update process stats (conditional on activity)
    let ctx_clone = Arc::clone(&context);
    let metrics_clone = Arc::clone(&metrics);
    // let reasoner_cfg = config.reasoner.clone(); // Unused
    tokio::spawn(async move {
        loop {
            // Only update when system is active (events/sec >= reasoner threshold)
            let eps = metrics_clone.events_per_sec();
            let is_active = eps >= 20; // Hardcoded default (YAGNI cleanup)

            if is_active {
                ctx_clone.update_process_stats();
            }

            sleep(Duration::from_secs(5)).await;
        }
    });

    // PSI-based circuit breaker with grace period
    if let Some(ref queue) = enforcement_queue {
        let cb_cfg = config.circuit_breaker.clone();
        let ctx_clone = Arc::clone(&context);
        let metrics_clone = Arc::clone(&metrics);
        let queue_clone = Arc::clone(queue);
        let incident_store_clone = incident_store.clone();
        let incident_analyzer_clone = incident_analyzer.clone();

        tokio::spawn(async move {
            if !cb_cfg.enabled {
                info!("[circuit_breaker] disabled by config");
                return;
            }

            let strategy = cb_cfg.escalation_strategy.as_str();
            info!(
                "[circuit_breaker] enabled - CPU>{}% AND PSI>{}% sustained for {}s (mode: {}, strategy: {}, panic_threshold: {}%)",
                cb_cfg.cpu_usage_threshold,
                cb_cfg.cpu_psi_threshold,
                cb_cfg.grace_period_secs,
                cb_cfg.mode,
                strategy,
                cb_cfg.psi_panic_threshold
            );
            if cb_cfg.escalation_strategy == "freeze_first" {
                info!(
                    "[circuit_breaker] freeze_first: PSI<{}% → freeze {}s, PSI>={}% → immediate kill",
                    cb_cfg.psi_panic_threshold,
                    cb_cfg.freeze_duration_secs,
                    cb_cfg.psi_panic_threshold
                );
            }

            let mut breach_started_at: Option<std::time::Instant> = None;
            // Track frozen processes: (pid, comm, frozen_at)
            let mut frozen_processes: Vec<(u32, String, std::time::Instant)> = Vec::new();

            loop {
                let snapshot = ctx_clone.get_system_snapshot();

                metrics_clone.set_psi_cpu(snapshot.psi_cpu_some_avg10);
                metrics_clone.set_psi_memory_some(snapshot.psi_memory_some_avg10);
                metrics_clone.set_psi_memory_full(snapshot.psi_memory_full_avg10);

                let is_breaching = snapshot.cpu_percent > cb_cfg.cpu_usage_threshold
                    && snapshot.psi_cpu_some_avg10 > cb_cfg.cpu_psi_threshold;

                if is_breaching {
                    if breach_started_at.is_none() {
                        breach_started_at = Some(std::time::Instant::now());
                        info!(
                            "[circuit_breaker] BREACH DETECTED - CPU={:.1}% PSI={:.1}% - grace period started",
                            snapshot.cpu_percent, snapshot.psi_cpu_some_avg10
                        );
                    } else {
                        let duration = breach_started_at
                            .expect("breach_started_at should be Some when in breach")
                            .elapsed()
                            .as_secs();
                        info!(
                            "[circuit_breaker] BREACH SUSTAINED - CPU={:.1}% PSI={:.1}% - {}s/{}s",
                            snapshot.cpu_percent,
                            snapshot.psi_cpu_some_avg10,
                            duration,
                            cb_cfg.grace_period_secs
                        );

                        if duration >= cb_cfg.grace_period_secs {
                            metrics_clone.inc_circuit_breaker_cpu_trip();
                            breach_started_at = None;

                            let mut top_cpu_procs = ctx_clone.top_cpu_processes(1);
                            if top_cpu_procs.is_empty() {
                                top_cpu_procs = ctx_clone.top_cpu_processes_systemwide(1);
                            }

                            if let Some(proc) = top_cpu_procs.first() {
                                // Get cgroup context for better attribution
                                let cgroup_context = get_process_cgroup_context(proc.pid);
                                let proc_context = if let Some(ref ctx) = cgroup_context {
                                    format!("[{}] {}({})", ctx, proc.comm, proc.pid)
                                } else {
                                    format!("{}({})", proc.comm, proc.pid)
                                };

                                let reason = format!(
                                    "CPU thrashing sustained {}s: CPU={:.1}% PSI={:.1}%",
                                    duration, snapshot.cpu_percent, snapshot.psi_cpu_some_avg10
                                );

                                // PANIC THRESHOLD: At extreme PSI levels, skip freeze and kill immediately.
                                // At >80% PSI, the kernel is essentially locked up - freeze is too risky.
                                let is_panic_level = snapshot.psi_cpu_some_avg10 >= cb_cfg.psi_panic_threshold;
                                
                                // Check escalation strategy (but override if panic level)
                                let use_freeze = cb_cfg.escalation_strategy == "freeze_first" && !is_panic_level;
                                
                                if is_panic_level {
                                    warn!(
                                        "[circuit_breaker] PANIC LEVEL DETECTED (PSI={:.1}% >= {:.1}%) - skipping freeze, executing SIGKILL",
                                        snapshot.psi_cpu_some_avg10, cb_cfg.psi_panic_threshold
                                    );
                                }
                                
                                // Check if this process is already frozen and needs escalation to kill
                                let already_frozen = frozen_processes.iter()
                                    .find(|(pid, _, frozen_at)| {
                                        *pid == proc.pid && 
                                        frozen_at.elapsed().as_secs() >= cb_cfg.freeze_duration_secs
                                    });

                                let action = if use_freeze && already_frozen.is_none() {
                                    // First offense: freeze the process (warning shot)
                                    frozen_processes.push((proc.pid, proc.comm.clone(), std::time::Instant::now()));
                                    cognitod::enforcement::ActionType::FreezeProcess { pid: proc.pid }
                                } else {
                                    // Either kill strategy, panic level, or freeze expired - execute kill
                                    frozen_processes.retain(|(pid, _, _)| *pid != proc.pid);
                                    cognitod::enforcement::ActionType::KillProcess {
                                        pid: proc.pid,
                                        signal: 9,
                                    }
                                };

                                let action_name = match &action {
                                    cognitod::enforcement::ActionType::FreezeProcess { .. } => "FROZEN",
                                    cognitod::enforcement::ActionType::KillProcess { .. } => {
                                        if is_panic_level { "PANIC_KILLED" } else { "KILLED" }
                                    },
                                    _ => "ACTION",
                                };

                                match queue_clone
                                    .propose_auto(
                                        action,
                                        reason.clone(),
                                        "circuit_breaker".to_string(),
                                        None,
                                        if cb_cfg.mode == "monitor" {
                                            false // Force manual approval in monitor mode
                                        } else {
                                            !cb_cfg.require_human_approval
                                        },
                                    )
                                    .await
                                {
                                    Ok(_) => {
                                        warn!(
                                            "[circuit_breaker] {} {}: {}",
                                            action_name, proc_context, reason
                                        );

                                        if let Some(store) = incident_store_clone.as_ref() {
                                            let incident = cognitod::Incident {
                                                id: None,
                                                timestamp: chrono::Utc::now().timestamp(),
                                                event_type: "circuit_breaker_cpu".to_string(),
                                                psi_cpu: snapshot.psi_cpu_some_avg10,
                                                psi_memory: snapshot.psi_memory_full_avg10,
                                                cpu_percent: snapshot.cpu_percent,
                                                load_avg: format!(
                                                    "{:.2},{:.2},{:.2}",
                                                    snapshot.load_avg[0],
                                                    snapshot.load_avg[1],
                                                    snapshot.load_avg[2]
                                                ),
                                                action: format!("auto_{}", action_name.to_lowercase()),
                                                target_pid: Some(proc.pid as i32),
                                                target_name: Some(proc.comm.clone()),
                                                system_snapshot: serde_json::to_string(&snapshot)
                                                    .ok(),
                                                llm_analysis: None,
                                                llm_analyzed_at: None,
                                                recovery_time_ms: None,
                                                psi_after: None,
                                            };

                                            let store_clone = Arc::clone(store);
                                            let analyzer_clone = incident_analyzer_clone.clone();
                                            tokio::spawn(async move {
                                                if let Ok(id) = store_clone.insert(&incident).await
                                                {
                                                    info!(
                                                        "[circuit_breaker] Incident #{} recorded",
                                                        id
                                                    );

                                                    if let Some(analyzer) = analyzer_clone {
                                                        tokio::spawn(async move {
                                                            match analyzer.analyze(&incident).await
                                                            {
                                                                Ok(analysis) => {
                                                                    let _ = store_clone
                                                                        .add_llm_analysis(
                                                                            id, analysis,
                                                                        )
                                                                        .await;
                                                                }
                                                                Err(e) => warn!(
                                                                    "[incident_analyzer] Failed: {}",
                                                                    e
                                                                ),
                                                            }
                                                        });
                                                    }
                                                }
                                            });
                                        }

                                        sleep(Duration::from_secs(30)).await;
                                    }
                                    Err(e) => {
                                        metrics_clone.inc_circuit_breaker_safety_veto();
                                        warn!("[circuit_breaker] safety veto: {}", e);
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Pressure normalized - unfreeze any frozen processes
                    if breach_started_at.is_some() {
                        info!("[circuit_breaker] conditions normalized - grace period reset");
                        breach_started_at = None;
                    }
                    
                    // Unfreeze processes if pressure is gone
                    for (pid, comm, _) in frozen_processes.drain(..) {
                        info!("[circuit_breaker] UNFREEZING {}({}) - pressure normalized", comm, pid);
                        let _ = queue_clone
                            .propose_auto(
                                cognitod::enforcement::ActionType::UnfreezeProcess { pid },
                                "Pressure normalized, resuming frozen process".to_string(),
                                "circuit_breaker".to_string(),
                                None,
                                true, // Auto-approve unfreeze
                            )
                            .await;
                    }
                }

                sleep(Duration::from_secs(cb_cfg.check_interval_secs)).await;
            }
        });
    }

    // Resource monitoring loop
    {
        let runtime_cfg = config.runtime.clone();
        tokio::spawn(async move {
            use procfs::{page_size, process::Process, ticks_per_second};
            let ticks = ticks_per_second() as f64;
            let page_kb = page_size() / 1024;
            let mut prev_total = 0u64;
            loop {
                if let Ok(stat) = Process::myself().and_then(|proc| proc.stat()) {
                    let total = stat.utime + stat.stime;
                    let dt = total.saturating_sub(prev_total);

                    if prev_total > 0 {
                        let cpu_pct = (dt as f64 / ticks) * 100.0;
                        let rss_mb = stat.rss * page_kb / 1024;
                        if cpu_pct > runtime_cfg.cpu_target_pct as f64 {
                            warn!(
                                "cpu usage {:.1}% exceeds target {}",
                                cpu_pct, runtime_cfg.cpu_target_pct
                            );
                        }
                        if rss_mb > runtime_cfg.rss_cap_mb {
                            warn!("rss {}MB exceeds cap {}", rss_mb, runtime_cfg.rss_cap_mb);
                        }
                    }
                    prev_total = total;
                }
                sleep(Duration::from_secs(1)).await;
            }
        });
    }

    // Enforcement executor loop - actually executes approved actions
    if let Some(ref queue) = enforcement_queue {
        let queue_clone = Arc::clone(queue);
        tokio::spawn(async move {
            loop {
                for action in queue_clone.get_all().await {
                    if action.status == cognitod::enforcement::ActionStatus::Approved {
                        match action.action {
                            cognitod::enforcement::ActionType::KillProcess { pid, signal } => {
                                info!("[enforcement] EXECUTING KILL pid={} signal={}", pid, signal);
                                unsafe {
                                    libc::kill(pid as i32, signal);
                                }
                                let _ = queue_clone.complete(&action.id).await;
                            }
                            cognitod::enforcement::ActionType::FreezeProcess { pid } => {
                                info!("[enforcement] EXECUTING FREEZE (SIGSTOP) pid={}", pid);
                                unsafe {
                                    libc::kill(pid as i32, libc::SIGSTOP);
                                }
                                let _ = queue_clone.complete(&action.id).await;
                            }
                            cognitod::enforcement::ActionType::UnfreezeProcess { pid } => {
                                info!("[enforcement] EXECUTING UNFREEZE (SIGCONT) pid={}", pid);
                                unsafe {
                                    libc::kill(pid as i32, libc::SIGCONT);
                                }
                                let _ = queue_clone.complete(&action.id).await;
                            }
                            cognitod::enforcement::ActionType::ThrottleCgroup { ref cgroup_path, quota_us, period_us } => {
                                info!("[enforcement] THROTTLING cgroup {} to {}/{}us", cgroup_path, quota_us, period_us);
                                let cpu_max_path = format!("{}/cpu.max", cgroup_path);
                                let value = format!("{} {}", quota_us, period_us);
                                match std::fs::write(&cpu_max_path, &value) {
                                    Ok(_) => info!("[enforcement] Successfully throttled {}", cgroup_path),
                                    Err(e) => warn!("[enforcement] Failed to throttle {}: {}", cgroup_path, e),
                                }
                                let _ = queue_clone.complete(&action.id).await;
                            }
                        }
                    }
                }
                sleep(Duration::from_secs(1)).await;
            }
        });
    }

    use tokio::net::TcpListener;
    use tokio::signal::unix::{SignalKind, signal};

    // --- Create AppState and pass to axum ---
    // Create alert history storage
    let alert_history = Arc::new(api::AlertHistory::new(1000));

    // Subscribe to alerts and populate history
    if let Some(ref tx) = alert_tx {
        let mut alert_rx = tx.subscribe();
        let history = Arc::clone(&alert_history);
        tokio::spawn(async move {
            while let Ok(alert) = alert_rx.recv().await {
                history.add_alert(alert).await;
            }
        });
    }

    let auth_token = std::env::var("LINNIX_API_TOKEN")
        .ok()
        .or(config.api.auth_token.clone());

    let app_state = Arc::new(AppState {
        context: Arc::clone(&context),
        metrics: Arc::clone(&metrics),
        alerts: alert_tx,
        insights: Arc::clone(&insight_store),
        offline: Arc::clone(&offline_guard),
        transport,
        probe_state,
        reasoner: config.reasoner.clone(),
        prometheus_enabled: config.outputs.prometheus,
        alert_history: Arc::clone(&alert_history),
        auth_token: auth_token.clone(),
        enforcement: enforcement_queue.clone(),
        incident_store: incident_store.clone(),
        k8s: k8s_context.clone(),
    });

    let api = all_routes(app_state.clone());
    let listen_addr = std::env::var("LINNIX_LISTEN_ADDR").unwrap_or(config.api.listen_addr.clone());
    let listener = TcpListener::bind(&listen_addr).await?;

    if listen_addr.starts_with("0.0.0.0") && auth_token.is_none() {
        warn!(
            "API listening on {} with NO AUTHENTICATION. \
            Set LINNIX_API_TOKEN to secure the API.",
            listen_addr
        );
    }

    info!("[cognitod] HTTP server on http://{}", listen_addr);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, api).await {
            eprintln!("server error: {e}");
        }
    });

    tokio::spawn(async {
        let mut sigterm = signal(SignalKind::terminate()).unwrap();
        sigterm.recv().await;
        println!("[cognitod] SIGTERM received, shutting down...");
        std::process::exit(0);
    });

    println!("[cognitod] Running. Press Ctrl+C to exit.");
    tokio::signal::ctrl_c().await?;
    println!("[cognitod] Shutting down...");
    // Try graceful shutdown for 3 seconds
    if timeout(std::time::Duration::from_secs(3), async {
        // Place any graceful shutdown logic here if needed
        // e.g., notify background tasks to stop, flush logs, etc.
    })
    .await
    .is_err()
    {
        println!("[cognitod] Graceful shutdown timed out, forcing exit.");
    }
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bpf_search_paths_canonical_order() {
        let paths = bpf_search_paths("test-bpf");

        // Should start with production install locations
        assert_eq!(paths[0], "/usr/local/share/linnix/test-bpf");
        assert_eq!(paths[1], "/usr/local/share/linnix/test-bpf.o");

        // Then development release builds (with relative path variants)
        assert_eq!(paths[2], "target/bpfel-unknown-none/release/test-bpf");
        assert_eq!(paths[3], "./target/bpfel-unknown-none/release/test-bpf");
        assert_eq!(paths[4], "../target/bpfel-unknown-none/release/test-bpf");
        assert_eq!(paths[5], "../../target/bpfel-unknown-none/release/test-bpf");

        // Finally legacy build paths
        assert_eq!(paths[6], "target/bpf/test-bpf.o");
        assert_eq!(paths[7], "./target/bpf/test-bpf.o");
        assert_eq!(paths[8], "../target/bpf/test-bpf.o");
        assert_eq!(paths[9], "../../target/bpf/test-bpf.o");

        // Total should match old implementation (10 paths)
        assert_eq!(
            paths.len(),
            10,
            "Should maintain same number of search locations"
        );
    }

    #[test]
    fn bpf_search_paths_maintains_backward_compatibility() {
        // Verify that all paths from the old CANDIDATES arrays are still covered
        let old_main_paths = [
            "/usr/local/share/linnix/linnix-ai-ebpf-ebpf",
            "/usr/local/share/linnix/linnix-ai-ebpf-ebpf.o",
            "target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf",
            "./target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf",
            "../target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf",
            "../../target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf",
            "target/bpf/linnix-ai-ebpf-ebpf.o",
            "./target/bpf/linnix-ai-ebpf-ebpf.o",
            "../target/bpf/linnix-ai-ebpf-ebpf.o",
            "../../target/bpf/linnix-ai-ebpf-ebpf.o",
        ];

        let new_paths = bpf_search_paths("linnix-ai-ebpf-ebpf");

        for (idx, old_path) in old_main_paths.iter().enumerate() {
            assert_eq!(
                &new_paths[idx], old_path,
                "Path order must be identical to preserve deployment compatibility"
            );
        }
    }
}
