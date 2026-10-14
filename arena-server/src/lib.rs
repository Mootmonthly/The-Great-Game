//! Dedicated arena server for The Great Game (docs/GAME_DESIGN.md §6.2–6.3):
//! champion verification by replay, matchmaking with Glicko-2 ratings,
//! lockstep matches, and permadeath.

pub mod glicko;
pub mod server;
pub mod sign;
pub mod steam;
pub mod store;
pub mod verify;
