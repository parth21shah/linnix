# Quick Start: Linnix Reasoner with Process Names

## Start Services

```bash
# 1. Start model server (in one terminal)
./serve_distilled_model.sh

# 2. Ensure cognitod is running (in another terminal)
sudo ./target/release/cognitod --config configs/linnix.toml
```

## Run Analysis

```bash
# Source environment
source .env.distilled

# Full analysis with process names
cargo run --release -p linnix-reasoner

# Short summary mentioning key processes
cargo run --release -p linnix-reasoner -- --short

# System insights
cargo run --release -p linnix-reasoner -- --insights
```

## Example Output

```
System Snapshot
  Timestamp: 1762193857
  CPU: 4.5%
  Mem: 49.2%
  Load: [0.42, 0.44, 0.89]

LLM Analysis:
The system is experiencing moderate CPU usage (4.48%) but high memory usage (49.19%),
with multiple processes consuming similar amounts of memory. The top processes include
VfsLoader (11.8%), Worker5 (11.8%), Worker0 (11.8%), each using significant memory.
Given the high memory usage, it's possible that some processes are not releasing
resources properly, leading to potential OOM conditions. Monitor these processes for
excessive memory consumption and consider optimization.
```

## What You Get

✅ **Process Names**: "VfsLoader", "chrome", "rustc", etc.
✅ **Resource Usage**: CPU %, memory %, memory MB
✅ **PIDs**: Process IDs for debugging
✅ **Top 10 Lists**: CPU consumers and memory consumers
✅ **Context-Aware**: LLM understands specific processes
✅ **Actionable**: Recommendations mention specific processes

## Run Demo

```bash
./demo_reasoner_with_processes.sh
```

This shows:
- Full analysis with process context
- Short summaries highlighting key processes
- Comparison with raw `ps` output
