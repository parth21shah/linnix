# Linnix Open Source Roadmap

**Last Updated**: November 3, 2025  
**Current Version**: v0.1.0 (MVP)

This roadmap outlines high-value features for the Linnix open-source community, prioritized by customer impact and adoption barriers.

---

## 🎯 **North Star Goals**

1. **Adoption**: Make it trivial to try Linnix (5-minute quickstart)
2. **Differentiation**: Show AI value that Datadog/New Relic don't offer
3. **Community**: Enable contributors to extend Linnix easily
4. **Enterprise Pipeline**: OSS users should naturally upgrade to Enterprise

---

## 🚀 **Q1 2026 (Immediate - Adoption Focus)**

### 1. **Docker Compose Quick Start** ⭐⭐⭐⭐⭐
**Priority**: CRITICAL  
**Effort**: 2 days  
**Impact**: Removes #1 adoption barrier

**Problem**: Currently requires manual eBPF build, systemd setup, separate llama.cpp server  
**Solution**: Single `docker-compose up` command

**Deliverables**:
```yaml
# docker-compose.yml
services:
  cognitod:
    image: linnixos/cognitod:latest
    privileged: true
    pid: host
    volumes:
      - /sys/kernel/btf:/sys/kernel/btf:ro
    ports:
      - "3000:3000"
      
  llama-server:
    image: linnixos/llama-cpp:latest
    volumes:
      - ./models:/models
    command: -m /models/linnix-3b-distilled-q5_k_m.gguf --port 8090
    
  linnix-dashboard:
    image: linnixos/dashboard:latest
    ports:
      - "8080:8080"
    environment:
      - COGNITOD_URL=http://cognitod:3000
```

**Success Metrics**:
- Time-to-first-insight: <5 minutes
- GitHub stars increase by 50%
- Demo video completion rate >80%

---

### 2. **Web Dashboard (Real-Time Visualization)** ⭐⭐⭐⭐⭐
**Priority**: CRITICAL  
**Effort**: 1 week  
**Impact**: Makes Linnix "feel" production-ready

**Problem**: CLI-only interface limits appeal to non-DevOps users  
**Solution**: Real-time web UI showing process tree, insights, alerts

**Tech Stack**:
- **Frontend**: React + TailwindCSS
- **Backend**: Cognitod SSE API (already exists!)
- **Charts**: Recharts or D3.js
- **Deployment**: Single static bundle served by cognitod

**Screens**:
1. **Home**: System overview (CPU/mem, events/sec, top processes)
2. **Process Tree**: Interactive d3 tree visualization with drill-down
3. **Insights**: AI analysis feed with timeline
4. **Alerts**: Active alerts with severity badges
5. **Metrics**: Prometheus-style time-series charts

**Key Features**:
- Live updates via SSE (no polling!)
- Process search and filtering
- Export insights to JSON/CSV
- Dark mode (obviously)

**Success Metrics**:
- 80% of demo users access dashboard
- Average session time >5 minutes
- Share rate on social media

---

### 3. **Pre-built Docker Images** ✅ DONE
**Priority**: HIGH  
**Effort**: 3 days  
**Status**: Docker images available on GHCR (ghcr.io/linnix-os/cognitod)

**Problem**: Users must build from source (cargo build takes 10+ min on slow machines)  
**Solution**: ✅ Published to GitHub Container Registry

**Available Images**:
- `ghcr.io/linnix-os/cognitod:latest` - eBPF monitoring daemon
- Multi-arch support (amd64, arm64)
- No Rust toolchain needed for users

---

## 📈 **Q2 2026 (Growth - Differentiation)**

### 4. **Kubernetes Operator** ⭐⭐⭐⭐
**Priority**: HIGH  
**Effort**: 2 weeks  
**Impact**: Unlocks platform engineering teams (large segment)

**Problem**: K8s users want DaemonSet deployment + CRDs for config  
**Solution**: Kubernetes-native deployment model

**Features**:
- DaemonSet: Auto-deploy cognitod to every node
- CRD: `LinnixConfig` for cluster-wide settings
- ServiceMonitor: Auto-configure Prometheus scraping
- RBAC: Proper permissions for eBPF

**Example**:
```yaml
apiVersion: linnix.io/v1
kind: LinnixConfig
metadata:
  name: production
spec:
  reasoner:
    enabled: true
    endpoint: http://llama-server:8090/v1/chat/completions
    model: linnix-3b-distilled
  probes:
    enablePageFaults: false  # production mode
  prometheus:
    enabled: true
```

**Success Metrics**:
- Helm chart downloads >500
- At least 2 companies using in production K8s

---

### 5. **Enhanced CLI with Rich TUI** ⭐⭐⭐⭐
**Priority**: MEDIUM  
**Effort**: 1 week  
**Impact**: Better UX for power users

**Problem**: Current CLI is basic text output  
**Solution**: Beautiful terminal UI with live updates

**Tech**: Ratatui (Rust TUI framework)

**Views**:
1. **Dashboard**: htop-style live process view
2. **Events**: Scrolling event stream with color-coding
3. **Insights**: AI analysis feed
4. **Logs**: Structured log viewer

**Example**:
```
╭─ Linnix v0.2.0 ──────────────────────────────────────╮
│ CPU: ████████░░ 82%  MEM: ██████░░░░ 63%             │
│ Events/sec: 124  Alerts: 2  Insights: 5              │
╰──────────────────────────────────────────────────────╯

┌─ Top Processes ──────────────────────────────────────┐
│ PID    Process              CPU%   MEM%   Status     │
├──────────────────────────────────────────────────────┤
│ 4412   java -Xmx4g          96.2%  12.1%  ⚠️ SPINNING│
│ 2891   python train.py       3.4%   8.3%  ✓ OK       │
└──────────────────────────────────────────────────────┘

┌─ Latest Insight (2s ago) ─────────────────────────────┐
│ 🤖 AI Analysis:                                        │
│ Java process (PID 4412) is in an infinite loop.      │
│ Recommendation: Capture thread dump with jstack       │
└───────────────────────────────────────────────────────┘
```

**Success Metrics**:
- CLI usage increases by 40%
- Time spent in CLI >2 minutes (engagement)

---

### 6. **Alerting Integrations** ⭐⭐⭐⭐
**Priority**: HIGH  
**Effort**: 1 week  
**Impact**: Makes Linnix production-ready for on-call teams

**Current State**: Alerts go to logs only  
**Goal**: Route to Slack, PagerDuty, email, webhooks

**Integrations**:
- **Slack**: Rich cards with process details
- **PagerDuty**: Auto-create incidents with AI context
- **Discord**: Community/startup teams
- **Generic Webhook**: Custom integrations
- **Email**: SMTP with HTML templates

**Config**:
```toml
[alerts.slack]
enabled = true
webhook_url = "https://hooks.slack.com/..."
channels = ["#incidents", "#alerts"]

[alerts.pagerduty]
enabled = true
routing_key = "..."
severity_mapping = { cpu_spin = "critical", fork_storm = "warning" }
```

**Example Slack Alert**:
```
🚨 Fork Storm Detected
PID 8821 (python) spawned 503 children in 12s

📊 Impact: CPU 94%, 1,200 processes
🤖 AI: Likely runaway pytest parallel execution
💡 Action: Kill PID 8821, limit pytest workers

[View in Linnix] [Acknowledge] [Snooze 1h]
```

**Success Metrics**:
- 50% of OSS users enable at least one integration
- Mean-time-to-acknowledge <2 minutes

---

## 🔧 **Q3 2026 (Maturity - Enterprise Features in OSS)**

### 7. **Multi-Tenancy / RBAC** ⭐⭐⭐
**Priority**: MEDIUM  
**Effort**: 2 weeks  
**Impact**: Enables shared deployments (MSPs, large orgs)

**Features**:
- API key authentication
- Role-based access (admin, viewer, analyst)
- Namespace isolation (team A can't see team B's processes)
- Audit logs

**Use Case**: Platform team runs one Linnix cluster for 10 dev teams

---

### 8. **Plugin System** ⭐⭐⭐
**Priority**: MEDIUM  
**Effort**: 2 weeks  
**Impact**: Community contributions and extensibility

**Goal**: Let users add custom:
- Event processors (e.g., detect SQL injection in postgres processes)
- Insight generators (e.g., Redis-specific anomaly detection)
- Exporters (e.g., send to S3, Kafka)

**Example Plugin** (WASM-based):
```rust
#[plugin]
fn analyze_postgres_slow_queries(event: ProcessEvent) -> Option<Insight> {
    if event.comm == "postgres" && event.cpu_percent > 80.0 {
        Some(Insight {
            class: "slow_query",
            why: "Long-running query detected",
            actions: vec!["Check pg_stat_statements"],
        })
    } else {
        None
    }
}
```

**Success Metrics**:
- At least 5 community plugins published
- Plugin marketplace on website

---

### 9. **Historical Data Storage** ⭐⭐⭐
**Priority**: MEDIUM  
**Effort**: 1 week  
**Impact**: Enables trend analysis and compliance

**Current State**: Events are in-memory only (last 60s)  
**Goal**: Persist to SQLite/Postgres for 30-day retention

**Features**:
- Query API: "Show me all fork storms in last week"
- Grafana datasource plugin
- Export to Parquet for data science

**Success Metrics**:
- 30% of users enable persistence
- Average retention: 7+ days

---

## 🌟 **Future Ideas (Q4 2026+)**

### 10. **Cost Dashboard** 💰
Compare Linnix costs vs Datadog/New Relic. Show "You're saving $X/month"

### 11. **Mobile App** 📱
iOS/Android for on-call engineers (push alerts, quick triage)

### 12. **VS Code Extension** 🧑‍💻
Debug processes directly from editor when tests fail

### 13. **eBPF Playground** 🎓
Educational tool to learn eBPF by modifying Linnix probes

### 14. **Auto-Remediation** 🤖
AI suggests + executes fixes (e.g., "kill PID 4412? [Y/n]")

---

## 📊 **Feature Prioritization Matrix**

| Feature | Customer Impact | Adoption Barrier | Effort | Score | Priority |
|---------|----------------|------------------|--------|-------|----------|
| **Docker Compose** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Low | 9.5 | **#1** |
| **Dashboard** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | Med | 9.0 | **#2** |
| **Docker Images** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Low | 8.5 | **#3** |
| **K8s Operator** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | High | 7.5 | #4 |
| **Alerting** | ⭐⭐⭐⭐ | ⭐⭐⭐ | Med | 7.0 | #5 |
| **Rich CLI** | ⭐⭐⭐ | ⭐⭐ | Med | 5.5 | #6 |
| **Multi-Tenancy** | ⭐⭐⭐ | ⭐⭐ | High | 4.0 | #7 |
| **Plugins** | ⭐⭐⭐ | ⭐⭐ | High | 4.0 | #8 |
| **Historical Data** | ⭐⭐⭐ | ⭐⭐ | Med | 5.0 | #9 |

---

## 🎯 **Recommended Execution Order**

### **Sprint 1 (This Month)**
1. Docker Compose quickstart
2. Pre-built Docker images
3. Basic web dashboard (read-only view of events/insights)

**Goal**: "5-minute demo" for first-time users

### **Sprint 2 (Next Month)**
1. Interactive dashboard (process tree drill-down)
2. Slack integration
3. Enhanced CLI (basic TUI)

**Goal**: "Production-ready" perception

### **Sprint 3 (Month 3)**
1. Kubernetes operator (DaemonSet + Helm)
2. PagerDuty integration
3. Dashboard: time-series charts

**Goal**: Enterprise-grade deployment options

---

## 💡 **Community Contribution Opportunities**

To encourage open-source contributions:

**Good First Issues**:
- [ ] Add dark mode to dashboard
- [ ] Discord webhook integration
- [ ] Export insights to CSV
- [ ] Grafana dashboard templates

**Help Wanted**:
- [ ] ARM64 Docker image optimization
- [ ] Windows support (WSL2 eBPF)
- [ ] OpenTelemetry exporter

**Bounties** (Paid):
- [ ] K8s operator ($500)
- [ ] Mobile app MVP ($1000)
- [ ] VS Code extension ($750)

---

## 📣 **Marketing Alignment**

Each feature should have:
1. **Blog Post**: Technical deep-dive
2. **Demo Video**: <2 minutes on YouTube
3. **Tweet Thread**: Launch announcement
4. **HN Post**: "Show HN: We built X for Linnix"

**Example**:
- Feature: Docker Compose quickstart
- Blog: "From Zero to AI Insights in 5 Minutes"
- Video: Screen recording with voiceover
- Tweet: "Tired of 10-page monitoring setup guides? Try Linnix..."
- HN: "Show HN: eBPF monitoring with AI in one docker-compose command"

---

## 🚦 **Success Criteria**

**By End of Q1 2026**:
- ✅ 1,000+ GitHub stars
- ✅ 500+ Docker Hub pulls
- ✅ 10+ production deployments
- ✅ 5+ community contributors
- ✅ 50+ Slack/Discord community members

**By End of Q2 2026**:
- ✅ 5,000+ GitHub stars
- ✅ 100+ production deployments
- ✅ 3+ case studies published
- ✅ 1+ enterprise customer (from OSS funnel)

---

## 🤝 **How to Contribute**

See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Development setup
- Code style guide
- PR process
- Community Code of Conduct

**Questions?** Join our [Discord](https://discord.gg/linnix) or open a [GitHub Discussion](https://github.com/linnix-os/linnix/discussions).

---

**Maintainers**: @parthshah (Founder)  
**Last Review**: November 3, 2025
