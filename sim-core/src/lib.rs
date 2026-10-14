//! The Great Game simulation core.
//!
//! Deterministic and engine-independent: the Godot client, the headless CLI,
//! and (later) the verification server all run this same code. See
//! docs/GAME_DESIGN.md §7.

pub mod action;
pub mod arena;
pub mod battle;
pub mod body;
pub mod brain;
pub mod fixed;
pub mod globe;
pub mod hash;
pub mod individual;
pub mod life;
pub mod presets;
pub mod render;
pub mod rng;
pub mod sheet;
pub mod star;
pub mod substance;
pub mod veil;
pub mod world;

pub use action::{Action, ActionLog};
pub use fixed::Fx;
pub use render::Overlay;
pub use world::World;
