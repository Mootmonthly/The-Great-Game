# The Great Game — Game Design Document (Draft v0.1)

> Status: living document. Sections marked **[OPEN]** need a decision before production on that system starts.

## 1. Product Summary

- **Genre:** God-game / evolution sandbox + competitive arena battler.
- **Platform:** Standalone downloadable PC game (Windows first, then Linux/Steam Deck, macOS). Distributed on Steam and similar storefronts. Not a browser game.
- **Fantasy:** You are the architect of a world. You seed it with matter, tune its physics and metaphysics, and watch life emerge in whatever form your rules allow. Then you take the best of what your world produced and send it to fight the creations of other gods.

## 2. Core Pillars

1. **Craft an evolving world.** Start from a blank petri dish. Add elements and molecules, tune temperature and conditions, and grow a biosphere. Viewed from on high.
2. **Write the laws of reality.** As life develops, define the rules: magic systems, physical laws, the power of the soul, Daoist cultivation, and more. Sapient life is possible, not guaranteed. Sapient species form civilizations, laws, and relationships. The player can possess any being and enter the world in first person.
3. **Life is not limited to carbon and water.** The simulation extrapolates life from whatever chemistry and metaphysics the world contains: classical fantasy creatures (goblins, dragons) and alien ones (hydrogen-silica goo demons) alike.
4. **Every being has a character sheet.** Beings receive stats in a D&D 5th-edition-style format and a **cost from 1 to 100** based on stats, innate abilities, and equipment.
5. **Champions fight online.** Players draft champions from their own world into a team under a fixed total cost cap and control them directly in an online arena, using their innate abilities.

## 3. Core Loop

```
 ┌──────────────── WORLD (single-player, long session) ────────────────┐
 │ Seed matter → tune environment → life emerges → set laws            │
 │      ↑                                              ↓               │
 │ spend Essence on new elements/laws ← observe, possess, intervene    │
 └───────────────────────────────┬─────────────────────────────────────┘
                                 │ "Bind" a being as a champion
                                 ▼
 ┌──────────────── ARENA (multiplayer, short session) ─────────────────┐
 │ Build roster under cost cap → match → real-time battle → results    │
 │      ↑                                                   ↓          │
 │ adjust roster ← earn Essence / cosmetics / ranking ←─────┘          │
 └─────────────────────────────────────────────────────────────────────┘
```

- **Essence** (working name) is the bridge currency. Arena play earns Essence. Essence unlocks rarer elements, exotic laws, and time acceleration in the world. **[OPEN]** Confirm whether world progression should be gated at all, or fully sandboxed with a separate "ranked seed" mode.

## 4. World Simulation

### 4.1 Simulation Layers (Level of Detail)

A full atom-level simulation of a planet is not feasible. The world runs at several fidelity levels at once and promotes detail only where the camera or a possessed being is.

| Layer | Scale | What it simulates | Tick rate |
|---|---|---|---|
| L0 Planetary | Whole world | Climate bands, atmosphere composition, ocean/solvent coverage, energy budget | Once per sim-year |
| L1 Regional | Hex/voxel regions (~10–100 km) | Chemistry pools, biomes, species populations, migration, civilizations | Once per sim-season |
| L2 Local | Area around camera (~1 km) | Individual creatures, ecology interactions, settlements | Real time when observed |
| L3 Embodied | Around possessed being | Full first-person gameplay, physics, combat | 60 Hz |

Rule: lower layers are the source of truth. Higher-detail layers are generated from them deterministically (seeded) and write back aggregate changes only.

### 4.2 Chemistry Model

Elements and molecules are data, not code. Each substance defines properties the life model can reason about:

- Phase transition temperatures (melting, boiling) at a given pressure.
- Bonding capacity (valence) and bond energy, for whether it can form long chains.
- Solvent quality (polarity, liquid range).
- Reactivity and energy release (as fuel or oxidizer).
- Optional **metaphysical properties** once laws allow them (mana conductivity, soul resonance, qi density).

The player adds substances to regions and adjusts temperature, pressure, and radiation. The L0/L1 simulation resolves which substances are solid, liquid, or gas and which reactions occur.

### 4.3 Life Viability: the "Life Triad"

Life can emerge in a region when three requirements are met. Each one has many possible answers:

1. **Backbone** — something that forms complex, stable structures. Carbon chains, silicon lattices, crystalline mana matrices, plasma knots, bound souls.
2. **Medium** — something that lets the components move and interact. Water, ammonia, methane, liquid sulfur, molten silicate, ambient mana.
3. **Energy gradient** — something to feed on. Sunlight, geothermal heat, chemical redox, radiation, ley lines, worship.

Each triad combination produces a **Biochemistry Profile**. The profile constrains everything downstream: temperature tolerance, metabolism speed, size limits, lifespan, natural weapons, and what counts as food or poison. Hydrogen-silica goo demons are one profile; oxygen-water mammals are another. New profiles appear automatically when the player adds new substances or laws, with no hand-authored list required.

### 4.4 Evolution

- Unit of simulation is the **species population** in a region (L1), not the individual.
- Each species has a **genome**: a vector of continuous traits (size, limb count, sensory modes, armour, metabolism, intelligence, reproduction rate, magical affinity, and so on), bounded by its Biochemistry Profile.
- Each sim-season: fitness is scored against region conditions and competing species; populations grow or shrink; traits mutate; isolated populations speciate.
- **Body Plan Synthesis:** the trait vector maps to a procedural body plan (skeleton/topology, locomotion, surface material) for rendering and animation.
- **Archetype Matcher:** trait vectors near a known fantasy archetype receive that archetype's name, silhouette hints, and signature ability. Example: large + flight + reptilian + exothermic gland → "Dragon" with a breath weapon whose damage type comes from the gland's chemistry. Beings that match no archetype get a generated name. This is how classical monsters and true aliens coexist.

### 4.5 Sapience and Civilization

- Sapience is a threshold on the intelligence trait plus social and manipulator traits. Many worlds never cross it. That is a valid outcome.
- Sapient species run an agent-based civilization model at L1: settlements, technology or magic progression, resource use, culture values, diplomacy, war.
- At L2, individuals get names, relationships (kin, rivals, allies, mentors), and a personal history. These feed the champion's backstory when bound.

### 4.6 Laws of Reality

Laws are unlockable rule modules that change simulation equations and unlock new traits and abilities. Each law has tunable parameters.

| Law | Effect on simulation | Example parameters |
|---|---|---|
| Arcane Magic | Adds a mana field to regions; unlocks spellcasting traits | Mana density, casting cost, school weights |
| Soul Power | Beings accumulate soul strength over a lifetime; enables reincarnation and soul-based abilities | Soul persistence, inheritance rate |
| Daoist Cultivation | Individuals can advance through cultivation realms by absorbing qi; growth beyond species norm | Qi density, realm thresholds, tribulation risk |
| Divine Favour | Worship generates energy for the player and grants blessings | Faith decay, miracle cost |
| Altered Physics | Change gravity, speed of sound, heat flow, entropy rate | Multipliers within safe bounds |

Laws can stack. Their interactions are the main source of emergent variety. **[OPEN]** Define the minimum law set for launch (suggest: Physics tuning, Arcane Magic, Cultivation).

### 4.7 Player Interaction (God Mode)

- Top-down orbital camera with smooth zoom from planet to ground level.
- Tools: add substance, heat/cool, adjust pressure, meteor/seed delivery, set law, accelerate time, bless/curse, observe (tracking overlays: population, chemistry, mana, civilizations).
- **Possession:** select any individual at L2 to drop into L3 first-person control. The creature's actual stats and abilities apply. Possession can be used for exploration, guiding a civilization, or testing a future champion.

## 5. Character Sheets

### 5.1 Format

Every individual can produce a sheet in a 5e-compatible format:

- **Ability scores:** STR, DEX, CON, INT, WIS, CHA (1–30), with modifiers.
- Size, type (generated from archetype or biochemistry), alignment (derived from civilization/culture values, or "Unaligned").
- Armour Class, Hit Points (hit dice from size and CON), speeds (walk, fly, swim, burrow, climb).
- Proficiency bonus, saving throws, skills.
- Damage resistances, immunities, vulnerabilities, condition immunities: derived from biochemistry. A silica-based being might resist fire and be vulnerable to thunder.
- Senses (darkvision, tremorsense, blindsight, truesight).
- Languages (for sapient beings).
- **Innate abilities:** actions, bonus actions, reactions, legendary actions where earned.
- **Equipment:** for beings in tool-using civilizations.

**Mapping simulation to sheet:** genome traits map to ability scores through fixed curves. Example: STR from size × muscle density; INT from intelligence trait; CHA from social trait plus soul strength. The same genome always produces the same base sheet. Individuals vary by a small seeded roll plus life history (training, cultivation realm, equipment).

### 5.2 Licensing Note

Mechanics from the D&D 5e System Reference Document (SRD 5.1) are released under Creative Commons CC-BY-4.0 and may be used commercially with attribution. The names "Dungeons & Dragons", "D&D", and non-SRD content (for example, specific trademarked monsters such as beholders and mind flayers) must not be used. Marketing should say "inspired by classic tabletop RPG character sheets." Include the required SRD attribution in the credits.

### 5.3 Cost (1–100)

Cost must be predictable, explainable to players, and resistant to exploits. Proposed formula, modelled on the 5e Challenge Rating approach (offence vs. defence):

```
DefensiveRating  = f(effective HP after resistances/immunities, AC, save bonuses)
OffensiveRating  = f(expected damage per round, attack bonus or save DC, range)
UtilityRating    = Σ ability utility scores (mobility, healing, control, summons, stealth)
StatRating       = Σ over 6 ability scores of max(0, score − 10)

Power  = 0.40·Defensive + 0.40·Offensive + 0.15·Utility + 0.05·Stat
         + EquipmentPower
Cost   = clamp(round(1 + 99 · (Power / PowerCap)^0.7), 1, 100)
```

- The 0.7 exponent spreads low-power beings across more cost values so cheap champions remain distinct.
- **PowerCap** is a tuned constant: the power of a reference top-tier being (roughly an ancient dragon) maps to about 95.
- Equipment adds power by the same offence/defence evaluation and is part of the champion's locked loadout.
- Each ability has a hand-tuned or simulation-derived utility score stored in data. A balance tool runs automated mock battles to re-tune weights (see §8).
- The sheet UI shows the cost breakdown so players understand why a being costs what it costs.

## 6. Arena

### 6.1 Mode

- **Format:** team battle, 1v1 player matches at launch (e.g. each player fields up to 4 champions). **[OPEN]** Champion count per team, and whether players control one champion at a time (swap) or command all of them.
- **Cost cap:** fixed per queue (for example 150 total cost). Alternative queues: low cap (50), solo champion (100 cap, 1 champion), unlimited casual.
- **Control:** real-time, third-person action combat. Players move their champion and trigger innate abilities mapped to hotkeys. Uncontrolled champions follow simple AI stances (aggressive, defensive, follow).
- **Translating 5e to real time:** turns become cooldowns. One "round" = 6 seconds. Actions have a cooldown or charge model; attack rolls happen on hit (accuracy vs. AC) so tabletop stats still matter; saves resolve against ability DCs. Legendary actions become extra charges.

### 6.2 Champion Binding and Integrity

- When the player binds a champion, the game takes an **immutable snapshot**: sheet, abilities, equipment, body plan, cosmetic data, and the computed cost.
- Snapshots are uploaded to the server and validated: the server recomputes cost from the sheet and rejects mismatches. The server also checks the sheet against generation rules (no impossible stat combinations).
- **[OPEN]** Whether a full world simulation must be verifiable (strong anti-cheat, high cost) or whether rule validation of the sheet is enough (recommended for launch).

### 6.3 Networking

- **Server-authoritative** dedicated servers, with client-side prediction and rollback for the player's own champion.
- Matchmaking by rating (Glicko-2) per queue.
- Steamworks for identity, friends, invites, and lobbies; dedicated servers on a cloud host for ranked play.

### 6.4 Balance Risk

Procedurally generated champions plus player-written laws can produce degenerate combinations. Mitigations:

- Laws have parameter bounds for ranked play. A "ranked-legal" flag on the world.
- Automated balance farm (headless arena sims) recalibrates ability utility scores between seasons.
- Global caps per ability category (e.g. hard crowd-control duration limit).

## 7. Technical Architecture (Proposal)

### 7.1 Engine **[OPEN]**

| Option | Pros | Cons |
|---|---|---|
| **Godot 4 (C#) + Rust/C++ simulation core via GDExtension** | No royalties, open source, good for procedural content, strong 3D in v4.x | Smaller ecosystem; dedicated-server tooling is less mature |
| **Unity 6 (C#, DOTS/ECS)** | Mature, DOTS suits large simulations, large asset ecosystem, Netcode for Entities | Runtime fee history, licensing risk |
| **Unreal Engine 5 (C++)** | Best visuals and netcode for action combat, mature dedicated servers | Heavy for a sim-first game, 5% royalty past threshold, steeper iteration |

**Recommendation:** Godot 4 with the simulation core written as a separate, engine-independent library (Rust or C++). This keeps the hardest part portable, testable, and runnable headless on servers and in the balance farm.

### 7.2 Module Layout

```
/sim-core        Deterministic, engine-independent simulation library
  chemistry/     Substances, phases, reactions
  biology/       Biochemistry profiles, genomes, evolution, archetype matcher
  civilization/  Agents, settlements, culture, diplomacy
  laws/          Law modules and parameter validation
  rules/         Character sheet generation, cost calculation, combat resolution
/game-client     Engine project: rendering, UI, god-mode tools, possession, arena client
/arena-server    Headless dedicated server (uses sim-core/rules)
/backend         Accounts (Steam), matchmaking, champion snapshot storage, ratings
/tools           Balance farm, data editors, world inspection tools
/data            Substances, traits, archetypes, abilities, laws (JSON/TOML)
```

### 7.3 Key Technical Principles

- **Determinism:** sim-core uses a seeded PRNG and fixed-point or carefully controlled floating point, so a world seed plus a player action log reproduces the same world. This enables save files, replays, and debugging.
- **Data-driven content:** substances, traits, archetypes, abilities, and laws are data files. Designers and modders add content without code changes. Steam Workshop support later.
- **Background simulation:** L0/L1 run on worker threads; the render thread never waits on simulation.
- **Save format:** versioned, compressed snapshot plus action log.

## 8. Roadmap (Proposed)

| Phase | Goal | Exit criteria |
|---|---|---|
| 0. Prototype: Petri Dish | 2D top-down. Add 10 substances, temperature control, life triad, species populations evolve | Two seeds with different chemistry produce visibly different life |
| 1. Prototype: Sheet & Cost | Genome → 5e sheet → cost. Headless auto-battler between two generated beings | Cost correlates with mock-battle win rate (target r > 0.8) |
| 2. Vertical Slice | 3D planet view, body plan synthesis, one law (Arcane Magic), possession, local 1v1 arena | Playable start-to-arena loop offline |
| 3. Online Alpha | Dedicated server, matchmaking, snapshot validation, cost-capped teams | Closed test with external players |
| 4. Content & Depth | Civilizations, more laws (Cultivation, Soul), archetypes, equipment | Sapient civs emerge in some fraction of worlds |
| 5. Early Access | Steam store page, Workshop, ranked seasons | Steam Early Access launch |

## 9. Open Questions Summary

1. Engine choice (§7.1).
2. Is world progression gated by Essence, or fully sandboxed (§3)?
3. Minimum law set for launch (§4.6).
4. Arena team size and control scheme (§6.1).
5. Anti-cheat depth for champion snapshots (§6.2).
6. Art direction: stylised or realistic? Stylised strongly recommended for procedural bodies.
7. Business model: premium price, with cosmetics only? Avoid pay-for-power given competitive play.
