#![allow(unused_imports)]
pub mod lineage;
pub mod probes;
pub mod sequencer;
pub mod stream_listener;

pub use sequencer::{
    OrderingValidator, SequencerConsumer, SequencerStats, disable_sequencer, enable_sequencer,
};
pub use stream_listener::start_perf_listener;

use std::sync::Arc;
use once_cell::sync::OnceCell;
use crate::handler::warmth::WarmthKeeper;

/// Global warmth keeper instance (set once at startup if enabled)
pub static WARMTH_KEEPER: OnceCell<Arc<WarmthKeeper>> = OnceCell::new();
