# Hosting the arena server

The arena server (`arena-server serve`) verifies champions, matches players and runs online matches (docs/GAME_DESIGN.md §6.2–6.3). It is one small program with one data folder. Players connect on TCP port 7878; every connection is encrypted.

## What it needs

- **CPU:**
  - Matches are cheap.
  - Verifying a champion replays the player's world: about 25 ms per simulated year the first time, and only the new part afterwards (checkpoints). The server uses at most half its cores for this.
  - A 2-vCPU machine is plenty for a closed test.
- **Memory:** about 50 MB plus a little per running match.
- **Disk:** the data folder holds accounts, ratings, champions, the ledger of the dead, and one world checkpoint of about 1.3 MB per player and world.
- **Network:** TCP port 7878 open to players.

## The data folder

| File | What it is |
|---|---|
| `state.json` | Accounts, ratings, bound champions, the ledger of the dead |
| `secret.key` | The server's signing key. Keep it private. If it changes, old champion tokens stop verifying. |
| `tls-cert.pem`, `tls-key.pem` | The self-signed certificate, made on first run. If it changes, players see an "impostor" warning until they click **Forget server certificate**. |
| `checkpoints/` | World snapshots that speed up re-binding. Safe to delete; the server just replays in full again. |

**Back up** `state.json`, `secret.key` and the TLS files. Stop the server first, or copy `state.json` while no match is ending.

## Option 1: your own computer

```
cargo run -p arena-server --release -- serve
```

Forward TCP port 7878 on your router to this computer and allow it through the firewall. Players connect to your public IP address.

## Option 2: a small cloud server with Docker

Any provider with a small Linux VM works, for example Hetzner, DigitalOcean, Linode or AWS Lightsail; the smallest plans (about $5 a month) are enough to start.

1. Install Docker on the VM and clone the repository.
2. Build and start:
   ```
   docker compose -f deploy/docker-compose.yml up -d --build
   ```
3. Allow TCP 7878 in the provider's firewall.
4. See the certificate fingerprint (to tell players what to expect):
   ```
   docker compose -f deploy/docker-compose.yml logs arena
   ```

State lives in the `arena-data` Docker volume.

To update: `git pull`, then run the `up -d --build` command again. Players' clients must use the same protocol version as the server; a mismatch is refused with "update the game".

## Option 3: a cloud server without Docker

Build the binary (`cargo build --release -p arena-server`), copy `target/release/arena-server` to `/usr/local/bin/` on the VM, and install the systemd unit in `deploy/arena-server.service` (instructions inside it).

## A real certificate (optional)

The self-signed certificate is safe: players pin it on first connect. With a domain name you can use a certificate players' games trust immediately:

1. Point a DNS name (for example `arena.example.com`) at the server.
2. Get a certificate with certbot: `certbot certonly --standalone -d arena.example.com`. Certbot needs port 80 open briefly.
3. Start the server with:
   ```
   --cert /etc/letsencrypt/live/arena.example.com/fullchain.pem --key /etc/letsencrypt/live/arena.example.com/privkey.pem
   ```
   With Docker, mount `/etc/letsencrypt` into the container (see the comments in `deploy/docker-compose.yml`).
4. Restart the server after certbot renews the certificate (every 60–90 days).

## Steam sign-in

Once the game has a Steam App ID, add `--steam-app <id> --steam-key <publisher Web API key>`. Use `--steam-only` to turn off name-and-secret accounts.

The Web API key is a secret: pass it through the environment or a private file, never the repository.

## Testing a server

From any machine:

```
cargo run -p arena-server --release -- bot --host <server address> --name tester1
cargo run -p arena-server --release -- bot --host <server address> --name tester2
```

The two bots evolve worlds, bind champions, find each other and fight. Each bot saves its account secret in `.arena-bot-<name>.secret`.
