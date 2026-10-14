# The-Great-Game
A game in which players cultivate their own world, and then choose champions from its denizens to battle other players.

## Prototype (Phase 0.5): the petri dish, bodies and minds

A 2D prototype of the world simulation. Seed a planet with substances, tune its star, gravity and temperature, and watch life emerge and evolve from whatever chemistry the world offers: carbon-water life on an Earth-like world, carbon-ammonia life on a frozen moon, sulfur life in molten sulfur pools, or silicon life swimming in magma. Lineages grow from single cells into creatures with eyes, shells, limbs, wings and chemical glands, each with a temperament from its own small neural network. Once nervous systems evolve, named individuals appear, make friends and enemies, and build up life stories.

### Repository layout

| Path | What it is |
|---|---|
| `sim-core/` | The simulation, in Rust. Deterministic and engine-independent. |
| `sim-cli/` | Headless command-line runner: run presets, verify replays, benchmark. |
| `godot-ext/` | GDExtension that exposes the simulation to Godot (`SimWorld`, `ArenaSim`, `NetClient`). |
| `net-proto/` | Client–server protocol for online play. |
| `arena-server/` | Dedicated arena server: champion verification, matchmaking, lockstep matches, permadeath. |
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
- **Planet:** drag the sliders to change star mass, star distance, star luminosity, planet radius, gravity, global temperature, day length and axial tilt. The change applies when you release the slider.
- **Mode and star:** pick a star type (red dwarf to neutron star) and a mode. In **Natural** mode physics links the settings: gravity comes from the planet's mass and radius, brightness from the star's type and mass, and moons too far out escape. **Godhand** mode lets you set anything, but impossible settings build up strain, which strips the atmosphere and heats the world. The panel shows year length, surface radiation, flares and strain.
- **Laws: the Veil:** the Veil separates the world from whatever lies beyond. Open it with the Veil slider, or strain reality with Godhand settings, a neutron star or many moons. Where it falls below 0.5, beings from beyond come through: Aberrations with eye clusters, tendrils and voids that feed on the minds of native creatures. Seal it again and they fade. The **Veil** map view shows where it is thin (violet) and where they live.
- **Moons:** add moons with a mass and distance, or remove the outermost. Close, heavy moons heat the planet with tides; a moon closer than 0.3 Earth–Moon distances is torn into rings, and one beyond the stable limit (about 2 for Earth) escapes in Natural mode.
- **Visit a region:** inspect a region, then click **Visit this region** to see it at ground level with its creatures wandering about. Click a creature to possess it and look through its eyes (WASD to move, drag to look, Esc to release). Visiting never changes the world.
- **Arena:** click **Enter the arena** to pick champions from your world under a cost cap and fight a rival world's champions. A rival world evolves while you choose. During the battle, click one of your units (blue rings) to possess it: WASD moves, Space attacks, Q breathes, Esc releases. Speed buttons run the fight at ×1, ×2 or ×4.
- **Save / Load:** saves the world's action log to your Godot user folder and replays it on load. The state hash under the status panel should be identical after loading.

Things to try:
- Start `blank`, add Water, Carbon and Nitrogen everywhere with a large radius, and watch where life starts.
- Move an Earth-like world to 0.5 AU or 3 AU and watch the oceans boil away or freeze.
- Lower gravity on an Earth-like world and watch large creatures appear.
- Run an Earth-like world for 150 years, then open the Veil to 100% and watch beings from beyond spread across the Veil map. Seal it and watch them fade.
- Switch an Earth-like world to a red dwarf, move it to 0.12 AU to keep it warm, and watch flares thin the air.
- Switch to Godhand, pick a neutron star, and set luminosity back to 1: the world stays warm but radiation kills unarmoured life unless you thicken the air.
- Run the `frozen_moon` preset for a few hundred years: nervous systems evolve quickly there, so named individuals show up early.

### Play online

The arena server verifies champions by replaying your world's history, matches players by cost cap and rating, and runs matches in lockstep.

1. **Start a server** (in a terminal, from the project folder):
   ```
   cargo run -p arena-server --release -- serve
   ```
   It listens on port 7878 and keeps its state in `server-data/`. To let friends on other machines connect, open port 7878 on your router or firewall and give them your IP address.

   Connections are encrypted. On first run the server makes its own certificate and prints its fingerprint. The game remembers it after the first connection and refuses a server that suddenly shows a different one (an impostor). If you reinstall the server on purpose, click **Forget server certificate** in the arena. A hosted server with a domain can use a real certificate instead: `--cert fullchain.pem --key privkey.pem`.
2. **Play:** in the viewer, open the arena and pick your team.
   - Under "Online", enter the server address (`127.0.0.1:7878` for your own machine), a player name, and Ranked or Practice.
   - The first time you use a name on a server, it becomes yours. The game saves a secret for it, and nobody else can sign in with that name.
   - Click **Find online match**. The server checks your champions, then waits for another player with the same cost cap.
   - To test alone, run a second copy of the viewer, or start a bot opponent:
     ```
     cargo run -p arena-server --release -- bot --name rival --cap 100
     ```
   To host a server for other people (your own computer, a cloud server, Docker, real certificates), see [docs/HOSTING.md](docs/HOSTING.md).
3. **Ranked is permadeath.** Named individuals who fall are gone forever: the server will never accept them again, and their death is written into your world's history. Species units that fall are lost, but the species can field more. Practice matches cost nothing.

During an online match, possession works as offline (WASD, Space, Q, Esc). Speed is fixed by the server, and **Surrender** ends the match at once.

If your connection drops, the arena AI fights for you. Click **Rejoin match** (or find a match again) within 30 seconds to pick up where you left off; after that, it counts as surrender.

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
cargo test -p net-proto -p arena-server --release                # server tests: verification, matches, permadeath
cargo run -p arena-server --release -- serve --speed 0            # server that runs matches as fast as possible (testing)
```

The `golden_hash` test checks that the simulation gives bit-identical results to a stored value. CI runs it on Windows, macOS and Linux. If it passes on your machine, your computer simulates worlds exactly like the server will.

### Headless viewer test

```
godot --headless --path game-client --editor --quit-after 300   # first-time import
godot --headless --path game-client -s res://tests/smoke_test.gd
```

## Documentation

- [Game Design Document](docs/GAME_DESIGN.md) — pillars, systems design, technical architecture, roadmap, and open questions.
