# Working agreements for Claude

These rules come from the project owner and apply to every session.

## Where things are recorded

- Game design decisions, rules and open questions go in `docs/GAME_DESIGN.md`. Never keep them only in Claude's memory or in chat.
- Use memory only for personal working notes that do not belong in the repository.
- When the owner makes a design decision in conversation, update `docs/GAME_DESIGN.md` (section text and §10 Decision Log) in the same change.

## Git

- Always push right after every commit, to the branch being worked on.
- The owner is the only other person on the repository. Claude is the only one committing.

## Checks before pushing

- `cargo test -p sim-core --release`
- `cargo clippy --workspace --release` (no warnings)
- If the simulation rules change on purpose, update the golden hashes in `sim-core/tests/determinism.rs`.
- If `game-client/` changes: import the project with `godot --headless --path game-client --editor --quit-after 300`, then run `godot --headless --path game-client -s res://tests/smoke_test.gd`.
