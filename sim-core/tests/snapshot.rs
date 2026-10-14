//! World snapshots: a restored world continues exactly like the original.
//! The arena server uses them as checkpoints (docs/GAME_DESIGN.md §6.2).

use sim_core::presets::preset_actions;
use sim_core::{Action, Fx, World};

#[test]
fn a_restored_world_continues_identically() {
    let mut w = World::new(5);
    for a in preset_actions(&w, "frozen_moon").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 600 });
    let bytes = w.snapshot();
    let mut r = World::from_snapshot(&bytes).unwrap();
    assert_eq!(r.state_hash(), w.state_hash());
    assert_eq!(r.log(), w.log());
    for world in [&mut w, &mut r] {
        world.apply(Action::SetVeilLaw {
            openness: Fx::ratio(7, 10),
        });
        world.apply(Action::Tick { ticks: 200 });
    }
    assert_eq!(r.state_hash(), w.state_hash());
    assert_eq!(World::replay(r.log()).state_hash(), w.state_hash());
    println!("snapshot size: {} KB", bytes.len() / 1024);
}

#[test]
fn snapshots_reject_garbage() {
    assert!(World::from_snapshot(b"{}").is_err());
    assert!(World::from_snapshot(b"not json").is_err());
}
