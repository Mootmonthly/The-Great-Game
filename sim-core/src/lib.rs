//! The Great Game simulation core.
//!
//! Deterministic and engine-independent: the Godot client, the headless CLI,
//! and (later) the verification server all run this same code. See
//! docs/GAME_DESIGN.md §7.

pub mod action;
pub mod fixed;
pub mod hash;
pub mod life;
pub mod presets;
pub mod render;
pub mod rng;
pub mod substance;
pub mod world;

pub use action::{Action, ActionLog};
pub use fixed::Fx;
pub use render::Overlay;
pub use world::World;
