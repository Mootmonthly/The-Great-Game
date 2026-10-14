# The-Great-Game
A game in which players cultivate their own world, and then choose champions from its denizens to battle other players.

## Prototype (Phase 0.5): the petri dish, bodies and minds

A 2D prototype of the world simulation. Seed a planet with substances, tune its star, gravity and temperature, and watch life emerge and evolve from whatever chemistry the world offers: carbon-water life on an Earth-like world, carbon-ammonia life on a frozen moon, sulfur life in molten sulfur pools, or silicon life swimming in magma. Lineages grow from single cells into creatures with eyes, shells, limbs, wings and chemical glands, each with a temperament from its own small neural network. Once nervous systems evolve, named individuals appear, make friends and enemies, and build up life stories.

### Repository layout

| Path | What it is |
|---|---|
| `sim-core/` | The simulation, in Rust. Deterministic and engine-independent. |
| `sim-cli/` | Headless command-line runner: run presets, verify replays, benchmark. |
| `godot-ext/` | GDExtension that exposes the simulation to Godot as the `SimWorld` class. |
| `game-client/` | Godot 4 project: the world viewer. |
| `data/substances.json` | The substance table. Edit it to add or change elements and molecules. |

### How the simulation works

- **Planet:** a 64 × 32 map of regions. One tick is one season; four ticks make a year.
- **Climate:** temperature comes from star distance and luminosity, latitude, greenhouse gases, altitude and geothermal hot spots. Thick atmospheres even out equator and poles.
- **Substance cycle:** each substance is solid, liquid or gas depending on local temperature and pressure. Gases rise into a shared atmosphere and fall back as rain or frost in cold regions. Liquids flow downhill into seas. Light gases escape to space from hot, low-gravity worlds.
- **Life triad:** life can start in a region that has a backbone element stable at the local temperature, a liquid medium, and an energy source (starlight, geothermal heat, or a fuel/oxidizer pair).
- **Evolution:** species grow, compete with others of similar size, hunt much smaller species, migrate, and split into new species adapted to their region.
- **Bodies:** each species has a body-part genome (segments, shells, fins, fronds, eyes, jaws, brains, tentacles, limbs, claws, wings, glands). Evolutionary milestones (multicellularity, nervous system, skeleton, glands, limbs, flight, sapience) unlock parts, and some depend on the world: flight needs low enough gravity and a thick enough atmosphere.
- **Brains:** every species carries a small neural network. Testing it in standard situations gives the species a temperament (aggression, fear, curiosity, sociability), which affects how it hunts, flees, cooperates and spreads.
- **Named individuals:** up to 300 beings with their own brains, personalities, relationships and memories. They travel, flee, fight and befriend each other; friends mourn and hold grudges. Each shows a Charisma preview for the future character sheet.
- **Determinism:** the simulation uses only integer (fixed-point) maths and a seeded random generator. A world is fully described by its seed plus the list of player actions. Saving a world saves that list, and loading replays it. This is the basis of server-side anti-cheat.

### Run the world viewer (Windows)

1. **Install Git:** download from https://git-scm.com/download/win and install with the default options.
2. **Install Rust:** download `rustup-init.exe` from https://rustup.rs and run it. If it offers to install the Visual Studio C++ build tools, accept. They are needed to compile Rust on Windows. Accept the default Rust installation.
3. **Install Godot 4.6:** download **Godot Engine 4.6.2 – Standard** (not the .NET version) for Windows from https://godotengine.org/download/archive/4.6.2-stable/. Unzip it anywhere. Godot needs no installer: the `.exe` is the whole program. Newer 4.x versions should also work.
4. **Open a terminal:** press the Windows key, type `PowerShell`, and press Enter.
5. **Download the project:**
   ```
   git clone https://github.com/Mootmonthly/The-Great-Game.git
   cd The-Great-Game
   ```
6. **Build the simulation:**
   ```
   cargo build --release
   ```
   The first build downloads dependencies and takes a few minutes. It creates `target\release\great_game_ext.dll`, which Godot loads.
7. **Open the project in Godot:** start the Godot `.exe`. In the Project Manager, click **Import**, browse to the `The-Great-Game\game-client` folder, select `project.godot`, and click **Import & Edit**. If Godot asks to upgrade or re-import the project, accept.
8. **Run it:** press **F5**, or click the play button (▶) at the top right of the editor.

The same steps work on Linux and macOS. Install Rust with the command shown on https://rustup.rs and use the Godot download for your system.

If the viewer says "The simulation extension is not loaded", step 6 did not finish. Run `cargo build --release` again, read any error, then restart Godot.

### Using the viewer

- **World:** pick a seed and a preset, then click **New world**. `blank` is an empty petri dish with bare rock and no atmosphere.
- **Time:** **Play** runs the simulation; **Speed** sets seasons per second. **+1 year** and **+10 years** step forward.
- **View:** switch the map between surface, temperature, life (each colour is a species), viability (where life could exist), and the amount of any single substance. Dots on the map are named individuals.
- **3D globe:** switch on "3D globe" under View to see the world as a stylised, rotating planet: toon-lit continents and seas, ice caps, glowing lava, clouds and an atmosphere tinted by its gases. Drag to rotate, scroll to zoom.
- **Species tab:** the largest living species. Click one to see a rotating 3D model built from its body parts, plus its milestones, traits, temperament and ancestry.
- **Family tree tab:** one line per species from its first year to extinction (or now), joined to its parent. Click a line to select it.
- **Individuals tab:** named individuals, most renowned first. Click one for its personality, relationships and life story.
- **Character sheets:** species and individual details end with a 5e-style stat block (ability scores, AC, HP, speeds, senses, resistances, traits, attacks, breath weapons) and the being's arena cost from 1 to 1000, with a breakdown of how the cost was reached.
- **God tools:** pick a tool, then click or drag on the map. **Add substance** and **Remove substance** use the selected substance, amount and radius. **Heat** and **Cool** change local temperature by 10 K per unit of amount. **Inspect** shows a region's chemistry, its best life triad, and the species living there.
- **Planet:** drag the sliders to change star distance, star luminosity, gravity and global temperature. The change applies when you release the slider.
- **Save / Load:** saves the world's action log to your Godot user folder and replays it on load. The state hash under the status panel should be identical after loading.

Things to try:
- Start `blank`, add Water, Carbon and Nitrogen everywhere with a large radius, and watch where life starts.
- Move an Earth-like world to 0.5 AU or 3 AU and watch the oceans boil away or freeze.
- Lower gravity on an Earth-like world and watch large creatures appear.
- Run the `frozen_moon` preset for a few hundred years: nervous systems evolve quickly there, so named individuals show up early.

### Command-line tools

```
cargo test -p sim-core --release                                 # unit and determinism tests
cargo run -p sim-cli --release -- presets                         # list presets
cargo run -p sim-cli --release -- run --preset frozen_moon --years 300
cargo run -p sim-cli --release -- run --preset earthlike --png out   # also write map images
cargo run -p sim-cli --release -- verify                          # save, replay, compare hashes
cargo run -p sim-cli --release -- bench                           # simulation cost per year
cargo run -p sim-cli --release -- sheets --preset earthlike --years 800   # character sheets and costs
cargo run -p sim-cli --release -- balance                         # check cost against the auto-battler (takes a few minutes)
```

The `golden_hash` test checks that the simulation gives bit-identical results to a stored value. CI runs it on Windows, macOS and Linux. If it passes on your machine, your computer simulates worlds exactly like the server will.

### Headless viewer test

```
godot --headless --path game-client --editor --quit-after 300   # first-time import
godot --headless --path game-client -s res://tests/smoke_test.gd
```

## Documentation

- [Game Design Document](docs/GAME_DESIGN.md) — pillars, systems design, technical architecture, roadmap, and open questions.
