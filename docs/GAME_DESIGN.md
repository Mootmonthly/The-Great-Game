# The Great Game — Game Design Document (Draft v0.2)

> Status: living document. Sections marked **[OPEN]** need a decision before production on that system starts.

## 1. Product Summary

- **Genre:** God-game / evolution sandbox + competitive arena battler.
- **Platform:** Standalone downloadable PC game (Windows first, then Linux/Steam Deck, macOS). Distributed on Steam and similar storefronts. Not a browser game.
- **Art style:** stylised, in the spirit of World of Warcraft: exaggerated proportions, bold silhouettes, hand-painted textures, saturated colour. This suits procedural creatures of unknown anatomy, keeps large battles cheap to render, and fits Godot's renderer.
- **Fantasy:** You are the architect of a world. You seed it with matter, tune its physics and metaphysics, and watch life emerge in whatever form your rules allow. Then you take the best of what your world produced and send it to fight the creations of other gods.

## 2. Core Pillars

1. **Craft an evolving world.** Start from a blank petri dish. Add elements and molecules, tune temperature and conditions, and grow a biosphere. Viewed from on high.
2. **Write the laws of reality.** As life develops, define the rules: magic systems, physical laws, the power of the soul, Daoist cultivation, and more. Sapient life is possible, not guaranteed. Sapient species form civilizations, laws, and relationships. The player can possess any being and enter the world in first person.
3. **Life is not limited to carbon and water.** The simulation extrapolates life from whatever chemistry and metaphysics the world contains: classical fantasy creatures (goblins, dragons) and alien ones (hydrogen-silica goo demons) alike.
4. **Every being has a character sheet.** Beings receive stats in a D&D 5th-edition-style format and a **cost from 1 to 1000** based on stats, innate abilities, and equipment.
5. **Champions fight online.** Players draft champions from their own world into a team under a fixed total cost cap and control them directly in an online arena, using their innate abilities. Team size is limited only by the cost cap. **Death in the arena is permanent.**

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

- **Essence** (working name) is the bridge currency. **Decided:** every world starts with a free set of basic resources. Players earn Essence by defeating other players in the arena and spend it to add extra and new resources beyond the basics.
- Essence cannot be bought with real money (see §9). Paid Essence would be pay-to-win in a competitive game with permadeath.
- **Snowball risk:** winners earn Essence and loot (§6.2a), which makes them stronger. Losers get nothing. Mitigations to test: rating-based matchmaking keeps opponents close in strength; diminishing Essence and loot value from repeat wins against much weaker players.

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
- Each species has a **genome**, bounded by its Biochemistry Profile, with three parts:
  - **Physiology:** size, temperature preference and tolerance, fecundity, metabolism.
  - **Body-part genome:** a list of parts (segments, shells, fins, fronds, eyes, jaws, brains, tentacles, limbs, claws, wings, glands), each with a count and size. Glands carry a substance from the local chemistry, which later sets their breath weapon or venom. Armour, speed, intelligence and offence are derived from the parts, never set directly.
  - **Brain genome:** a small neural network (§4.8).
- **Evolutionary milestones** gate which parts a lineage can grow. Each needs its predecessors plus suitable conditions in the world:

  | Milestone | Requires | Condition | Unlocks |
  |---|---|---|---|
  | Multicellularity | — | Dense, well-fed population | Segments, shells, fins, fronds; size above microscopic |
  | Nervous system | Multicellularity | — | Eyes, jaws, brains, tentacles; behaviour (§4.8) |
  | Skeleton | Multicellularity | Enough structural material in the local chemistry | Large bodies |
  | Chemical glands | Multicellularity | A reactive substance in the region | Glands |
  | Limbs | Skeleton + nervous system | — | Limbs, claws |
  | Flight | Limbs | Gravity ≤ 2 g, pressure ≥ 0.15 bar | Wings |
  | Sapience | Nervous system | High intelligence, manipulators (limbs or tentacles), sociable temperament | Named civilisations (later phases) |

- Each sim-season: fitness is scored against region conditions and competing species; populations grow or shrink; species compete within size niches and hunt much smaller species; genomes mutate; populations speciate.
- **Sapience rule (decided):** an unmodified, stable Earth-like world should produce sapient life almost every time, given enough time. Worlds that never reach sapience should be the result of unusual player choices (exotic chemistry, broken orbital dynamics, harsh laws), not the basic Earth template.
- How the simulation achieves this:
  - **Feedback loop:** as with hands, social life and brains on Earth, lineages with manipulators (limbs or tentacles) and a sociable temperament grow brains faster, and clever, social tool-users compete better.
  - **Awakening:** a species that is clever, social and has manipulators can become sapient in any season, not only when a new species splits off.
  - **Competitive exclusion:** each sapient species already alive makes further awakenings less likely, and sapient lineages split into new species far less often. A world ends up with a handful of sapient peoples, not hundreds. That suits fantasy settings with several peoples (elves, dwarves, goblins).
- Pace (Phase 0.5 prototype, Earth-like world): multicellular life within about 100 years, nervous systems and skeletons within about 300, sapience usually within about 500–1,000 years (all 8 test seeds by year 1,000), limbs and flight within about 1,000.
- **Body Plan Synthesis:** the body-part genome maps to a procedural body plan (skeleton/topology, locomotion, surface material) for rendering and animation.
  - **Prototype (Phase 2):** `game-client/creature_builder.gd` assembles a stylised model from the parts list: segments become a chain of rounded body blobs (the head grows with brain size), eyes sit in pairs on the head, jaws form a snout, shells form a dome, fronds splay from the back, limbs attach in pairs with claws on the front feet, fins become dorsal, side and tail fins, wings become flapping sails, tentacles become waving chains, and glands become a glowing throat sac in their substance's colour. Single cells are pulsing blobs with a whip tail. Procedural animation walks the legs, flaps the wings and waves tentacles and tails. Final art will replace the primitive shapes with an artist-made parts kit using the same attachment rules.

![Procedurally built creatures from three simulated worlds](images/creature-gallery.png)
- **Archetype Matcher:** trait vectors near a known fantasy archetype receive that archetype's name, silhouette hints, and signature ability. Example: large + flight + reptilian + exothermic gland → "Dragon" with a breath weapon whose damage type comes from the gland's chemistry. Beings that match no archetype get a generated name. This is how classical monsters and true aliens coexist.

### 4.4a Extradimensional Beings

Not all life has to come from the world's own chemistry. Some beings come from outside reality: Lovecraftian, extradimensional entities that do not follow the life triad at all.

- **The Veil:** a measure of how separate the world is from whatever lies beyond. Each region has a Veil strength; where it is thin, things can come through.
- **What thins the Veil (proposed):**
  - **Player laws:** a "Veil" setting among the metaphysical laws, from sealed to wide open. Exotic Veil-thinning resources can be unlocked with Essence.
  - **Extreme physics:** strong gravity wells, frequent eclipses from many moons, and Godhand-mode settings that break real physics all strain reality.
  - **Metaphysics:** mana convergence (Arcane Magic), mass deaths releasing souls (Soul Power), and cultivators breaking through to higher realms.
  - **Minds:** sapient cultures whose religions reach outwards (§4.8, level 6). Worship can call things in.
- **Biology without chemistry:** extradimensional beings need no backbone, medium or energy gradient. They feed on what the world's minds and metaphysics produce: thought, fear, souls, mana. In the population simulation, they draw energy from nearby species with nervous systems and raise those species' fear, rather than eating biomass.
- **Bodies:** their own body-part set, not bound by gravity or the square-cube law: impossible geometry, phase membranes that exist partly elsewhere, eye clusters, tendrils, voids. They ignore normal size caps.
- **Minds:** alien brains with extra senses and outputs. Their temperament may read as incoherent to the world's creatures. They can become named individuals. Their presence warps relationships: cults form around them, and they compete with the player as objects of worship.
- **Character sheet:** type Aberration. Typical traits: psychic damage, Frightened and madness effects, truesight, telepathy, resistance to non-magical damage. Usually high cost.
- **Risk and reward:** a world with a thin Veil can produce the strongest champions in the game, but the entities can destabilise or consume the world's own life. They can arrive uninvited if the player creates the right conditions, so world-building choices have consequences.
- **Naming:** all entities get original generated names. No names from commercial mythos products.
- **Physics alone is enough (decided):** extreme enough physics can thin the Veil even in a world with no metaphysical laws at all. A purely physical world is safer, not immune.
- **Implemented (prototype):**
  - *Veil strength:* each region has a Veil from 0 (wide open) to 1 (sealed). It moves 20% of the way toward its target each season.
  - *Planet-wide thinning:*
    - The Veil law: 0–100% open, worth up to 0.8.
    - Reality strain (§4.6) s: worth 0.8 × s / (s + 3).
    - Eclipses: 0.05 per moon beyond the second, up to 0.3.
  - *Local variation:* seeded fault lines give each region from 0.7× to 1.3× the planet-wide thinning. Beings already through hold their region open by a further 0.1.
  - *Breaches:* each region below 0.5 adds to the breach chance per season: 0.0002 × (0.5 − Veil), at most 25% for the planet. Thinner regions are likelier breach points.
  - *New kinds:* a breach brings a new kind of being, up to 8 kinds alive at once. After that, more of an existing kind comes through.
  - *Physics alone:* a Natural neutron star thins the Veil to about 0.6–0.8 but it holds. Godhand settings that break physics (for example, a neutron star shining like the Sun) open it.
  - *Bodies:* new parts no native lineage can evolve:
    - Eye clusters (2–8 eyes).
    - Tendrils.
    - Phase membranes (armour, +2 AC).
    - Voids (offence).
    - Sometimes jaws.
    - Size from half to about 40× human, beyond native size caps. Bodies are random, with alien brains wired at random.
  - *Feeding:* they ignore the life triad and temperature. Carrying capacity per region is 0.5 × the biomass of nearby native minds (nervous-system species, weighted by intelligence), plus a little from the Veil itself (4 × openness²). Each season they drain native minds in proportion to their own biomass and hunting. They fade where the Veil is strong: death rate 0.03 + 0.25 × Veil².
  - *Spread and behaviour:* they spread toward minds and thin places, and do not speciate.
  - *Effect on native minds:*
    - Native individuals count them as a major threat and flee them.
    - Native individuals remember the first time they glimpse one.
    - The beings themselves can become named individuals.
    - At 100% open on an Earth-like world, native minds lose about 10% of their biomass to them within a century, and more after.
    - Sealing the Veil again makes them fade within about 50 years.
  - *Character sheet:*
    - Type Aberration, alignment "Unknowable".
    - Resistance to bludgeoning, piercing, slashing and psychic damage.
    - Truesight 60 ft. with 4+ eyes, otherwise darkvision 120 ft.; telepathy 120 ft.
    - Tendril attacks, plus a psychic Mind Lash. A void gives a Void Pulse (psychic, Wisdom save).
    - Maddening Presence: in the arena, enemies within 30 ft. must pass a Wisdom save each round or attack with disadvantage.
    - Higher Intelligence and Charisma than native creatures. They float, with walk and fly speeds.
  - *Viewer:* Veil overlay, Veil law slider, Veil readout, violet sky tint on the globe, and floating models with tendrils, voids and a shimmering membrane.
  - *Not yet:* mass deaths (Soul Power), mana convergence (Arcane Magic), cultivation breakthroughs, worship (religions, §4.8 level 6), cults, and Essence-unlocked Veil resources. These thinning sources arrive with their systems.

### 4.5 Sapience and Civilization

- Sapience is a threshold on the intelligence trait plus social and manipulator traits. Many worlds never cross it. That is a valid outcome.
- Sapient species run an agent-based civilization model at L1: settlements, technology or magic progression, resource use, culture values, diplomacy, war.
- At L2, individuals get names, relationships (kin, rivals, allies, mentors), and a personal history. These feed the champion's backstory when bound.

### 4.6 Laws of Reality

**Decided launch set: planetary and physical controls.** The player controls these from the start:

| Control | Range / notes | What it drives |
|---|---|---|
| Temperature | Global baseline plus regional heat/cool tools | Phases of substances, biome bands, life triad viability |
| Planetary composition | Elements and molecules in crust, mantle, and oceans/solvents | Available backbones, minerals, volcanism, magnetic field |
| Atmospheric composition | Gases and their proportions, surface pressure | Breathable/usable gases, greenhouse effect, sky colour, flight viability |
| Gravity | Surface gravity multiplier | Maximum creature size, flight cost, atmosphere retention, mountain height |
| Rotation speed | Day length; optional axial tilt | Day/night cycle, temperature swings, wind patterns, seasons |
| Star distance and orbital speed | Distance from the star and orbital period | Energy received, year length, climate zones |
| Star properties | Star type and luminosity (suggested) | Light spectrum, radiation level, photosynthesis-style energy |
| Moons | Number of moons; each with mass, distance, and orbital speed | Tides, eclipses, night light, orbital stability, impact risk |

**Physics coupling:** in real physics, orbital period follows from distance and star mass, and gravity follows from planet mass and radius. Two modes are proposed:

- **Natural mode:** linked values update together. Unstable configurations (for example, moons too close or too many) degrade over time with visible consequences such as tidal breakup or moons colliding.
- **Godhand mode:** each value is set independently, which is physically impossible but fun. **Decided:** allowed in ranked worlds. Godhand worlds are hard to make viable: impossible settings cause harsh side effects (for example, extreme tidal stress, atmosphere loss, or runaway heating), so only skilled players get good results.

**Implemented so far (Phase 2):**
- **Day length:** days longer than Earth's add a day–night temperature swing (thick air holds heat overnight). Life must tolerate both the hot day and the cold night, so very slow-turning worlds are harder on life.
- **Axial tilt:** seasons. Each year one hemisphere warms while the other cools, then they swap; thick atmospheres damp the swing.
- **Moons:** each has a mass and a distance. Tides heat the planet (like Io's volcanoes) and add energy for life. A moon placed inside the Roche limit (0.3 Earth–Moon distances) is torn apart into rings; a moon on nearly the same orbit as another collides and merges with it. Up to 12 moons.
- The globe shows the tilt, a spin rate that follows the day length, orbiting moons and rings.
- **Natural and Godhand modes** (new worlds start in Natural):
  - *Natural:* the planet has a mass and a radius, and gravity = mass / radius². Asking for a gravity changes the planet's mass instead. The star's brightness follows from its type and mass (main-sequence stars: L ∝ M^3.5); asking for a brightness picks the closest mass the star type allows. Year length follows Kepler: √(distance³ / star mass), and long years mean stronger seasons. Moons beyond the stable limit (about 1.95 Earth–Moon distances × distance in AU × ∛(planet mass / star mass)) escape.
  - *Godhand:* gravity, brightness and moons are set freely. The distance from what physics allows is the world's **strain**: |log₂(gravity / natural gravity)| + |log₂(brightness / natural brightness)| + ½ per moon beyond the stable limit, capped at 20. Strain bleeds the atmosphere away (0.4% per point per season, up to 5%) and adds 8 K of heat per point. Switching back to Natural snaps the values back to physics.
- **Star types:** eight types. Each sets the light quality for light-powered life, a harmful radiation level, and the sun's colour on the globe.

  | Star | Mass (suns) | Brightness | Light quality | Radiation | Notes |
  |---|---|---|---|---|---|
  | Red dwarf | 0.1–0.5 | 0.015 | 0.5 | 0.6 | Flares (5% per season) strip the atmosphere |
  | Orange dwarf | 0.5–0.8 | 0.25 | 0.85 | 0.2 | Steady; good home for life |
  | Yellow dwarf | 0.8–1.2 | 1 | 1 | 0.2 | Sun-like |
  | White star | 1.2–2.5 | 5 | 1 | 0.6 | |
  | Blue giant | 2.5–30 | 3000 | 0.9 | 2 | Planets must orbit far out |
  | Red giant | 0.8–3 | 300 | 0.6 | 0.3 | Dying star, not main sequence |
  | White dwarf | 0.5–1.3 | 0.002 | 0.7 | 0.5 | Only very close planets stay warm |
  | Neutron star | 1.4–2.1 | 0.0001 | 0.1 | 8 | Strains reality |

  Brightness is at the typical mass. Radiation is relative to the Sun's, and falls with distance squared. The atmosphere shields the surface: dose = flux / (1 + 2 × pressure in bar). A dose above 1 (an airless Earth's) harms life, with armour as a shield, and speeds up speciation through mutation.
- **Reality strain** (feeds the Veil, §4.4a): Godhand strain, +2 around a neutron star, and log₂(gravity / 5) above 5 g.
- **Eclipses:** every moon beyond the second thins the Veil (§4.4a). Eclipse visuals are not built yet.

Extra and exotic resources (rare elements, unusual molecules, more moons, unusual star types) are unlocked with Essence.

**Decided launch set: metaphysical laws.** Arcane Magic, Soul Power, and Daoist Cultivation ship at launch alongside the planetary controls. Divine Favour and further Altered Physics are post-launch candidates. Metaphysical laws are rule modules that change simulation equations and unlock new traits and abilities. Each law has tunable parameters.

| Law | Effect on simulation | Example parameters |
|---|---|---|
| Arcane Magic | Adds a mana field to regions; unlocks spellcasting traits | Mana density, casting cost, school weights |
| Soul Power | Beings accumulate soul strength over a lifetime; enables reincarnation and soul-based abilities | Soul persistence, inheritance rate |
| Daoist Cultivation | Individuals can advance through cultivation realms by absorbing qi; growth beyond species norm | Qi density, realm thresholds, tribulation risk |
| Divine Favour | Worship generates energy for the player and grants blessings | Faith decay, miracle cost |
| Altered Physics | Change speed of sound, heat flow, entropy rate beyond the launch controls | Multipliers within safe bounds |

Laws can stack. Their interactions are the main source of emergent variety.

### 4.7 Player Interaction (God Mode)

- Top-down orbital camera with smooth zoom from planet to ground level.
- Tools: add substance, heat/cool, adjust pressure, adjust orbit/rotation/gravity, add/remove moons, meteor/seed delivery, set law, accelerate time, bless/curse, observe (tracking overlays: population, chemistry, mana, civilizations).
- **Possession:** select any individual at L2 to drop into L3 first-person control. The creature's actual stats and abilities apply. Possession can be used for exploration, guiding a civilization, or testing a future champion.
  - **Prototype (Phase 2):** from the region inspector, **Visit this region** builds a ground-level scene from the region's simulated state: terrain with seas sized to its liquids (lava glows on hot worlds, ice whitens cold ones), sky tinted by the atmosphere, and creatures from its populations (more biomass, more creatures; swimmers stay in the water) with its named individuals labelled. Click one to possess it: first-person view from its eyes, WASD to move, drag to look, its character sheet in the HUD. Following the camera rule (§4.8), the visit is display only; a test checks the world's state hash is unchanged.

![Region visit and first-person possession](images/region-visit-possession.png)

### 4.8 Minds: Neural Networks

Every being's behaviour comes from a small neural network in its genome: 8 senses (food, threat, prey, stranger, kin, hunger, injury, bias), 6 hidden neurons, 4 actions (approach, flee, attack, socialise). Brains use fixed-point maths, so they are as deterministic as the rest of the simulation and replay verification still works. One decision costs about 200 multiply-adds; one CPU core manages about 1–2 million per second.

Brains run at several levels, chosen so cost stays bounded:

![Neural-network feasibility levels](images/neural-network-feasibility.png)

(Source for the image: `images/neural-network-feasibility.html`.)


| Level | What runs | Scale | Where | Status |
|---|---|---|---|---|
| 1. Species instincts | Each species' brain is tested once in standard situations. The answers become its temperament (aggression, fear, curiosity, sociability), which drives hunting, fleeing, pack cooperation and migration in the population simulation. | Every species | Main simulation | Phase 0.5 |
| 2. Named individuals | Persistent beings with a personal variant of their species' brain, a personality, health, renown, relationships and memories. They act every season: travel, flee, fight, befriend. Deaths are mourned, and killers earn grudges. | About 300 now; target 1,000–10,000 | Main simulation | Phase 0.5 (groundwork) |
| 3. Crowds near the camera | Ordinary creatures around the camera get full brains and act in real time. | About 10,000–50,000 | Display only | Later |
| 4. Relationships | Bonds between individuals: kinship, trust, rivalry, love, debt. | Thousands of links | Main simulation | Phase 0.5 (affinity and kinship) |
| 5. Culture | Settlements hold shared values. Ideas (rituals, taboos, crafts, beliefs) spread person to person; each individual's brain decides whether to adopt them. | Per settlement | Main simulation | Later |
| 6. Religion | Beings explain events they cannot account for. The player's interventions are real, witnessable events, so religions can form around the player. Different cultures may read the same act differently. | Per culture | Main simulation | Later |
| 7. Arena AI | A champion's personality steers a tactical arena AI: cautious beings keep their distance, loyal ones protect allies. | About 1,000 units per match | Arena server | Later |
| 8. Language | Made-up languages per culture plus templated speech. An optional AI language model may add flavour lines during possession, as cosmetics only. | — | Display only | Later |

**Camera rule:** anything that affects the world (named individuals, relationships, culture, religion) runs in the main simulation, independent of the camera, so replay verification reproduces it. Crowds near the camera are display only: moving the camera must never change the world.

**Feeding the character sheet (§5):**
- **Charisma:** sociability, number of friendships, and renown. The prototype shows a CHA preview for named individuals.
- **Intelligence and Wisdom:** brain size and complexity, plus life experience for named individuals.
- **Alignment:** personality plus cultural values.
- **Backstory:** a named champion carries its real relationships, deeds and memories.

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
- **Equipment:** for beings in tool-using civilizations. See §5.4.

**Mapping simulation to sheet (implemented, `sim-core/src/sheet.rs`):**
- **Ability scores:** STR from body size (log scale), limbs and weapons; DEX from speed, reduced by bulk; CON from size and armour; INT from brain size (+4 if sapient); WIS from eyes, caution and age; CHA from sociability, or for named individuals from friendships and renown. A human-sized, unremarkable body scores about 10 in each; an elephant-sized one has STR about 22.
- **Hit dice:** grow with body mass (about 1 for a person, 9 for an elephant, 22 for an ancient dragon); the die comes from the size category (d4 Tiny … d20 Gargantuan).
- **Armour class:** 10 + DEX modifier + up to 9 from shell armour.
- **Attacks from parts:** jaws bite, claws slash (up to two attacks), tentacles strike; a body with no weapons slams. Large, coordinated bodies get an extra attack. A gland gives a breath weapon whose damage type comes from its substance (methane or hydrogen: fire; ammonia: acid; carbon dioxide or water: cold; iron or silicon: lightning; sulfur: poison).
- **Resistances from biochemistry:** cold-adapted life resists cold and is vulnerable to fire; hot-adapted life is immune to fire and vulnerable to cold; silicon life resists fire and is vulnerable to thunder; sulfur life is immune to poison; heavy armour resists physical damage; mindless life is immune to psychic damage.
- **Type:** Ooze (single-celled), Humanoid (sapient), Dragon (winged, four or more limbs, breath, large), Elemental (non-carbon life), Plant, Monstrosity or Beast.
- **Alignment:** sapient beings only, from personality (sociability, curiosity, aggression); others are Unaligned.
- **Traits:** Sunfed (fronds regenerate in sunlight), Pack Tactics (sociable), Keen Senses, Flyby, Amorphous, Tool User.

Earlier note: genome traits map to ability scores through fixed curves. Example: STR from size × muscle density; INT from intelligence trait; CHA from social trait plus soul strength. The same genome always produces the same base sheet. Individuals vary by a small seeded roll plus life history (training, cultivation realm, equipment).

### 5.2 Licensing Note

Mechanics from the D&D 5e System Reference Document (SRD 5.1) are released under Creative Commons CC-BY-4.0 and may be used commercially with attribution. The names "Dungeons & Dragons", "D&D", and non-SRD content (for example, specific trademarked monsters such as beholders and mind flayers) must not be used. Marketing should say "inspired by classic tabletop RPG character sheets." Include the required SRD attribution in the credits.

### 5.3 Cost (1–1000)

Cost must be predictable, explainable to players, and resistant to exploits.

**Implemented formula (Phase 1):**

```
EffectiveHP  = HP / P(hit by +7 vs this AC) × 0.65 × toughness × regeneration
               toughness: +10% per resistance, +20% per immunity, −10% per vulnerability (0.7–2.0)
DamagePerRound = Σ attacks: P(hit AC 15) × average damage × attacks per round
               with a breath weapon: (breath × 0.8 + 2 × attacks) / 3 when the breath is stronger
Utility      = flight 15%, swimming 5%, burrowing 5%, darkvision/tremorsense 5%, tool use 10%
Stats        = 1 + Σ max(0, score − 10) / 1000

Power = √(EffectiveHP × DamagePerRound) × (1 + Utility) × Stats
Cost  = clamp(round(Power × 0.85), 1, 1000)
```

- **Why power is a square root, and cost is linear in power:** in a duel, A beats B when A's effective HP × damage per round exceeds B's. The square root of that product is additive under Lanchester's square law: ten units of power 10 fight about as well together as one unit of power 100. So cost linear in power prices armies of cheap units and single champions fairly against each other at the same total cost. This replaces the earlier proposal (a 0.7 exponent), which would have made large champions systematically cheaper than the armies they face.
- **Calibration anchors (tested):** a 5e-style commoner costs 1; an ancient-dragon-like being (546 HP, AC 22, fire breath, flight) costs about 310. A reference apex being (for example, a dragon living on a neutron-star-like world) should reach about 1000 once equipment and metaphysical laws add power.
- **Measured against the auto-battler** (`sim-cli balance`: 3,500+ evolved species from 4 presets × 2 seeds, 155 sampled across the cost range):
  - Rank correlation between cost and win rate: **0.93** (Phase 1 target: above 0.8).
  - In pairs with at least a 1.5× cost gap, the more expensive side won **99%** of match-ups.
  - Armies of n cheap units against one unit costing n× as much: the army wins about **55%** (50% is perfectly fair). Large single-target hitters waste damage on small targets (overkill), which the formula does not yet model. Tune when arena rules exist.
- Ability scores may exceed the 5e cap of 30 for extreme beings. The cost formula stays monotonic beyond that range.
- Equipment adds power by the same offence/defence evaluation and is part of the champion's locked loadout (later phase).
- The sheet UI shows the cost breakdown (effective HP, damage per round, power, utility, abilities) so players understand why a being costs what it costs.

### 5.4 Equipment (decided, built in the content phase)

- **Gear fits body parts, not body types (decided).** There is no "humanoid only" rule. Each item attaches to a kind of part, and any being with that part can use it:

  | Part | Gear |
  |---|---|
  | Limbs with manipulators | Held weapons, shields, tools |
  | Tentacles | Held weapons, one per pair |
  | Jaws | Jaw-held or jaw-mounted weapons (blade bits, iron fangs) |
  | Body and segments | Armour shaped to the body plan: plates, barding, shell inlays |
  | Wings | Wing blades, light harness |
  | Glands | Breath foci that widen or lengthen a breath weapon |
  | Brain (sapient or telepathic) | Mind foci, charms |
  | Parts from beyond the Veil | Unique relics: void shards, phase anchors |

- **Making and using (proposed detail):** only sapient, tool-using civilizations make gear. Passive gear (armour, barding, charms) works on any body it fits. Active gear (held weapons, foci) also needs enough Intelligence to use well.
- **Unique gear by chemistry:** items carry the substance, damage type and laws of the world that made them. For example, silicon life forges heat-proof crystal blades, and beings from beyond make relics no native can craft.
- **Refitting looted gear (decided):** looted gear can be refitted to a different body plan at a cost (cost unit to be set: resources, Essence or time). Until refitted, it fits only bodies with the parts it was made for.
- **Timing (decided):** built in the content phase (roadmap phase 4).

## 6. Arena

### 6.1 Mode

- **Format:** 1v1 player matches at launch. Map types, match length, and victory conditions are deferred until the world simulation is complete.
- **Decided: team size is variable.** The only limit is the total cost cap. Example with a 1000 cap: one player brings 1000 one-cost chumps; the other brings a single 1000-cost neutron-star dragon. Both are legal.
- **Cost cap:** fixed per queue. Default queue: 1000. Suggested extra queues: skirmish (250), duel (1 champion, 1000 cap), unlimited casual.
- **Control scheme (proposed):** armies of any size need two control layers:
  - **Command layer (RTS-style):** select units or groups, issue move/attack/hold orders, set AI stances (aggressive, defensive, follow).
  - **Possession layer (action-style):** take direct third-person control of any one champion at a time and trigger its innate abilities from hotkeys. Switch between champions freely.
- **Decided: unit cap of 500 per side** (1000 per match) for launch. Reassess once the game is built. Even this scale requires an ECS-style arena simulation, crowd pathfinding, GPU-instanced rendering, and animation level of detail for distant units.
- With a 1000 cost cap and a 500-unit cap, the cheapest legal army is 500 two-cost units, or a mix such as 400 one-cost units plus higher-cost champions.
- **Translating 5e to real time:** turns become cooldowns. One "round" = 6 seconds. Actions have a cooldown or charge model; attack rolls happen on hit (accuracy vs. AC) so tabletop stats still matter; saves resolve against ability DCs. Legendary actions become extra charges.

### 6.1a Arena prototype (Phase 2)

A local, offline prototype (`game-client/arena.gd`), reached from the viewer's **Enter the arena** button:
- **Teams:** your champions come from your world: its strongest distinct species (any number of copies) and its most renowned named individuals (one each, marked ★). The rival's come from a different world that evolves on the spot (Earth-like, frozen moon or sulfur world, random seed). Both sides pick under the same cost cap (25, 50, 100, 250 or 1000), up to 40 units a side; auto-pick fills a team greedily.
- **Combat:** the character sheets in real time. One 5e round is 1.5 s of arena time. Units walk to the nearest enemy (keeping apart from allies) and attack with their sheet's attacks: d20 + to-hit against armour class, critical hits on 20, damage dice, resistances, immunities and vulnerabilities. Breath weapons hit the nearest enemies in front, with a save for half, and recharge on 5–6. Regeneration and pack tactics apply.
- **Possession:** click one of your units to take control: WASD moves it relative to the follow camera, Space attacks, Q uses its breath weapon, Esc releases it.
- **Result:** the battle ends when one side is wiped out. The log notes which champions fell; permadeath and looting are not yet applied to the world.
- **Deterministic core:** the match runs in the Rust core (`sim-core/src/arena.rs`, exposed to Godot as `ArenaSim`) in fixed 0.1 s steps with fixed-point positions. Godot only renders it and forwards player commands (possess, steer, attack, breathe), which are logged with the step they applied on. `Arena::replay` rebuilds a match from the two rosters, the seed and the command log and reaches the same result: the basis for server authority (§6.3). Tested.
- **Not yet:** the network layer and dedicated server, online opponents, match structure and victory conditions (open question 1), surrender.

![Arena prototype: methane-breathing winged dragons from a frozen moon against a rival world](images/arena-battle.png)

### 6.2 Champion Binding and Integrity

- When the player binds a champion, the game takes an **immutable snapshot**: sheet, abilities, equipment, body plan, cosmetic data, and the computed cost.
- Snapshots are uploaded to the server and validated: the server recomputes cost from the sheet and rejects mismatches. The server also checks the sheet against generation rules (no impossible stat combinations).
- **Decided: strict anti-cheat.** The server must be able to prove that a champion really evolved in a legitimately simulated world.

**Option A — server-hosted worlds.** The world simulation runs only on the server; the client is a viewer.

- Strongest guarantee: the client never holds the true world state.
- Requires always-online play, even for single-player world building. Steam players often criticise this.
- God-mode tools feel laggy, because every change waits on the network.
- Ongoing cost per active player. Rough estimate: 0.25–1 vCPU per running world at about $0.02–0.05 per vCPU-hour, so about $0.005–0.05 per player-hour. A player with 100 hours costs about $0.50–5.00. If worlds keep evolving while the player is offline, cost rises to about $45–440 per world per year. This must be avoided.
- These numbers are order-of-magnitude assumptions.
- **Measured (Phase 0.5 prototype):** a fully populated world costs about 20–30 ms of one CPU core per simulated year, including named individuals. Replaying 1,000 simulated years to verify a champion takes about 20–30 CPU-seconds.

**Option B — deterministic replay verification (decided).** The client runs the world. The server re-runs it to verify.

- The sim-core is fully deterministic (fixed-point maths, seeded PRNG). A world is fully described by its seed plus the player's action log.
- The client uploads the action log (kilobytes, not gigabytes) whenever the player binds a champion.
- The server replays the log headless, with no rendering, typically 20–100 times faster than real play. It checks that the replayed world contains the bound champion with the same sheet and cost.
- Each successful verification stores a signed checkpoint, so the next verification replays only from the last checkpoint.
- Rough cost: 1–5% of Option A. That is about $0.01–0.25 per player lifetime.
- Equally strict as Option A, provided determinism holds on every platform. Offline world building still works; only binding and arena play need a connection.
- Constraint: anything that changes a being's sheet must be in the log. Recommendation: possession (L3) does not change sheets, which keeps replays short.

At a $10–20 box price, Steam's cut leaves about $7–14 per copy and there is no recurring revenue. Option B keeps server costs a small fraction of that.

**Implemented (Phase 3 prototype, `arena-server/`):**
- The client uploads its world's seed and action log when it binds a champion. The server replays the log headless and rebuilds the sheet itself. It rejects a cost mismatch, a missing or dead being, or any edited log (an edit changes the world, so the claimed champion no longer matches).
- Limits per verification: 200,000 actions and 10,000 simulated years, so one request cannot use unbounded CPU. Replays share half the server's cores.
- A verified champion becomes a server-signed token (HMAC-SHA256). The server keeps the authoritative sheet and appearance; clients refer to champions only by token, so a client cannot alter them afterwards.
- Not yet: signed checkpoints, so a re-bind replays only the new part of the log. Today every bind replays the whole history (about 25 ms per simulated year).

### 6.2a Permadeath

- **Decided:** a champion that dies in the arena is dead forever.
- The dead individual is removed from its home world. Its species, descendants, and civilization continue.
- **Decided: loot.** The bodies and gear of every fallen champion go to the victorious player. The loser gets nothing.
  - **Bodies** become resources in the winner's world. Example: a fallen dragon's scales become a rare material, or a goo demon's remains introduce a new substance that may seed new life.
  - **Gear** goes to the winner's inventory and can be equipped on the winner's own beings. Gear keeps its own properties, even if it comes from laws the winner's world does not use. Equipped loot counts toward the wearer's cost.
  - **Integrity:** the server issues every loot grant as a signed record. Loot enters the winner's action log, so replay verification (§6.2) accepts it.
- Death makes every match high stakes. A 1000-cost apex being can be lost in one defeat. This is intended tension, but needs supporting rules:
  - **Decided:** surrender ends a match early. Champions that already fell stay lost and are looted; survivors return home.
  - Clear pre-match preview of the opponent's total cost, but not their exact roster (proposed).
  - Unranked practice queue against AI or friends with no permadeath (proposed; a practice queue against other players exists in the prototype).
- **Implemented (prototype):**
  - In ranked matches, every champion whose unit falls is removed from its owner's account.
  - Fallen named individuals go into a **ledger of the dead**, keyed by a fingerprint of the being: world seed, id, species, birth tick and name. No account can bind them again, from the same save or from any branch of their world replayed with different later actions. Reloading an old save does not bring a champion back.
  - The client logs the death in its world (`Action::ChampionFell`), so the world replays without them.
  - Species champions are rank-and-file members of a species. A fallen unit is lost, but the species lives on and can supply more units (proposed rule).
  - Looting (bodies, gear) is not built yet; it waits for the Essence economy and equipment (§5.4).

### 6.3 Networking

- **Server-authoritative** dedicated servers run the arena simulation.
- With up to 2000 units, replicating every unit's state is expensive. Recommended model: clients send inputs only; the server and clients all run the same deterministic arena simulation (lockstep with server validation, as in many RTS games). Client-side prediction smooths the possessed champion.
- Matchmaking by rating (Glicko-2) per queue.
- Steamworks for identity, friends, invites, and lobbies; dedicated servers on a cloud host for ranked play.

**Implemented (Phase 3 prototype):**
- **Server** (`arena-server serve`): a plain TCP server speaking newline-delimited JSON (`net-proto/`).
  - One thread per connection.
  - Each match runs on its own thread at 10 arena ticks per second.
  - State is kept in a JSON file: accounts, ratings, champion tokens and the ledger of the dead.
- **Matchmaking:** two queues, ranked and practice. Players are matched by queue and identical cost cap, against the closest Glicko-2 rating waiting.
  - Teams are checked server-side: 1–500 champions, all owned, none already queued or fighting, total cost within the cap.
  - The first ranked match moves a new rating by about ±160.
- **Lockstep:**
  - Clients send only commands for their own units. The server rewrites or drops commands for the other side.
  - Each tick the server applies the commands, steps the authoritative arena and broadcasts that tick's commands. Clients step an identical arena.
  - Every 50 ticks the server sends a state hash, and clients flag any desync.
  - The match result and the fallen are decided by the server and signed.
- **Surrender and disconnects:** surrender ends the match at once; the other side wins, the fallen stay fallen and survivors go home. Disconnecting during a match counts as surrender (proposed rule).
- **Test tools:** `arena-server bot` is a headless player that evolves a world, binds champions, queues and lets the arena AI fight.
- **Not yet:** Steam identity (names are taken on trust), TLS, reconnecting to a running match, client-side prediction of the possessed unit (commands take one round trip), cloud hosting, and the Essence economy.

### 6.4 Balance Risk

Procedurally generated champions plus player-written laws can produce degenerate combinations. Mitigations:

- Laws have parameter bounds for ranked play. A "ranked-legal" flag on the world.
- Automated balance farm (headless arena sims) recalibrates ability utility scores between seasons.
- Global caps per ability category (e.g. hard crowd-control duration limit).

## 7. Technical Architecture (Proposal)

### 7.1 Engine — **Decided: Godot 4**

| Option | Pros | Cons |
|---|---|---|
| **Godot 4 (C#) + Rust/C++ simulation core via GDExtension** | No royalties, open source, good for procedural content, strong 3D in v4.x | Smaller ecosystem; dedicated-server tooling is less mature |
| **Unity 6 (C#, DOTS/ECS)** | Mature, DOTS suits large simulations, large asset ecosystem, Netcode for Entities | Runtime fee history, licensing risk |
| **Unreal Engine 5 (C++)** | Best visuals and netcode for action combat, mature dedicated servers | Heavy for a sim-first game, 5% royalty past threshold, steeper iteration |

**Decision:** Godot 4. The simulation core is a separate, engine-independent library (Rust recommended, loaded through GDExtension). This keeps the hardest part portable, testable, and runnable headless on servers, in replay verification (§6.2), and in the balance farm.

### 7.2 Module Layout

```
/sim-core        Deterministic, engine-independent simulation library
  chemistry/     Substances, phases, reactions
  biology/       Biochemistry profiles, genomes, evolution, archetype matcher
  civilization/  Agents, settlements, culture, diplomacy
  laws/          Law modules and parameter validation
  rules/         Character sheet generation, cost calculation, combat resolution
/game-client     Engine project: rendering, UI, god-mode tools, possession, arena client
/arena-server    Headless dedicated server (uses sim-core/rules) — implemented
/net-proto       Client–server protocol and lockstep match mirror — implemented
/backend         Accounts (Steam), matchmaking, champion snapshot storage, ratings
/tools           Balance farm, data editors, world inspection tools
/data            Substances, traits, archetypes, abilities, laws (JSON/TOML)
```

### 7.3 Key Technical Principles

- **Determinism:** sim-core uses a seeded PRNG and fixed-point maths, so a world seed plus a player action log reproduces the same world on every platform. This is required for anti-cheat (§6.2) and enables save files, replays, and debugging.
- **Data-driven content:** substances, traits, archetypes, abilities, and laws are data files. Designers and modders add content without code changes. Steam Workshop support later.
- **Background simulation:** L0/L1 run on worker threads; the render thread never waits on simulation.
- **Save format:** versioned, compressed snapshot plus action log.

## 8. Roadmap (Proposed)

**Visual test (done before Phase 1):** a stylised 3D globe built from a simulated world: toon lighting with a hard day/night edge, height-based relief, seas with glints, ice, lava with glowing cracks, banded clouds, and an atmosphere glow coloured by the simulated gases. It is a test of the art direction (§1), not final art.

![Globe visual test: Earth-like, frozen moon, sulfur world, magma world](images/globe-visual-test.png)

![Tilted Earth-like world with three moons and rings from a moon torn apart](images/globe-moons-rings.png)


| Phase | Goal | Exit criteria |
|---|---|---|
| 0. Prototype: Petri Dish | Godot 4 + Rust sim-core. 2D top-down. 10 substances, temperature, gravity, star distance; life triad; species populations evolve. Determinism test across Windows and Linux | Two seeds with different chemistry produce visibly different life; identical replay hashes on both platforms; measured sim cost per world-hour |
| 0.5 Prototype: Bodies & Minds | Body-part genomes, evolutionary milestones, brain genomes and temperament, named individuals with relationships, family tree view | Lineages progress from microbes to limbed, winged creatures; individuals form friendships and feuds; replay stays deterministic |
| 1. Prototype: Sheet & Cost (done) | Genome → 5e sheet → cost. Headless auto-battler between two generated beings | Cost correlates with mock-battle win rate (target r > 0.8) |
| 2. Vertical Slice (in progress) | 3D planet view, full planetary controls (rotation, orbit, moons, atmosphere), body plan synthesis, possession, local 1v1 arena with small armies | Playable start-to-arena loop offline |
| 3. Online Alpha (in progress) | Dedicated server, replay verification, matchmaking, permadeath, Essence economy, large-army arena (500 units per side) | Closed test with external players |
| 4. Content & Depth | Civilizations, metaphysical laws (Arcane Magic, Soul Power, Daoist Cultivation), the Veil and extradimensional beings, archetypes, equipment, loot | Sapient civs emerge in some fraction of worlds |
| 5. Early Access | Steam store page, Workshop, ranked seasons | Steam Early Access launch |

**Phase 2 status:** done: stylised 3D globe; day length, axial tilt, moons and rings; procedural creature models from body-part genomes; local arena with cost-capped teams, real-time 5e-style combat and possession of a unit. Region visits with first-person possession are also done. The arena's rules now run in the deterministic Rust core with replayable command logs. Natural/Godhand modes and star types are done. A prototype of the Veil and extradimensional beings (§4.4a, planned for phase 4) was pulled forward. Remaining: final art and the network layer.

**Phase 3 status:** done: dedicated server with replay verification, signed champion tokens, ranked and practice queues with Glicko-2 matchmaking, lockstep online matches, permadeath with a ledger of the dead, and online play from the arena screen. Remaining: Steam identity, cloud hosting, reconnects, client-side prediction, the Essence economy and looting, and large-army arena work (500 units per side).

## 9. Business Model

- **Decided:** premium "box price" on Steam, about $10–20 per copy. Final price depends on product quality and scope.
- No pay-for-power. Essence is earned only through play.
- Optional later revenue that does not affect balance: cosmetic packs, soundtrack, expansions that add new law modules.
- Server costs must stay well below net revenue per copy. This drives the choice of replay verification (§6.2).

## 10. Decision Log

| # | Question | Decision |
|---|---|---|
| 1 | Engine | Godot 4, with a Rust sim-core |
| 2 | World progression | Gated: free basic resources; Essence earned by defeating players unlocks extra and new resources |
| 3 | Launch law set | Planetary and physical controls (temperature, planet and atmosphere composition, gravity, rotation, star distance and orbit, moons), plus Arcane Magic, Soul Power, and Daoist Cultivation |
| 4 | Arena team size | Variable, limited by cost cap (1–1000 scale) and 500 units per side |
| 5 | Anti-cheat | Strict; Option B, deterministic replay verification (§6.2) |
| 6 | Art direction | Stylised, World of Warcraft-like |
| 7 | Business model | Box price on Steam, about $10–20 |
| — | Champion death | Permanent; winner loots all bodies and gear, loser gets nothing |
| — | Godhand mode | Allowed in ranked; hard to make viable |
| — | Surrender | Allowed; fallen champions are looted, survivors return home |
| — | Evolution model | Body-part genomes gated by evolutionary milestones, with neural-network brains used as far as cost allows (§4.4, §4.8) |
| — | Sapience on Earth-like worlds | Almost always, given time; "never sapient" worlds come from unusual player choices (§4.4) |
| — | Cost formula | Power = √(effective HP × damage per round), cost linear in power; commoner 1, ancient dragon about 310 (§5.3) |
| — | Natural/Godhand and star types | Built as in §4.6: Natural is the default; Godhand strain thins the air and heats the world; eight star types with light quality, radiation and flares (numbers open to tuning) |
| — | Online server (prototype rules) | Species champions are rank and file and can be bound again; named individuals die forever via a ledger of the dead; disconnecting mid-match counts as surrender; a practice queue exists (§6.2–6.3). Open to change |
| — | Equipment | Gear attaches by body part, not body type; looted gear is refitted to other body plans at a cost; built in the content phase (§5.4) |
| — | The Veil | Built as in §4.4a: a Veil law slider (0–100% open), reality strain and many moons thin it; beings from beyond feed on native minds and fade when the Veil is sealed (numbers open to tuning) |
| — | Extradimensional beings | Included as a possibility, arriving through a thin Veil; extreme physics alone can let them in (§4.4a) |

## 11. Open Questions

Deferred until the world simulation is complete:

1. Arena match structure: map types, match length, and victory conditions (§6.1). The owner finds the current arena bare-bones; it will be revisited after the online server.
2. Practice queue details (§6.2a).
