# Factory

Cloud agent orchestrator. Spins up ephemeral DigitalOcean VMs, runs Claude Code autonomously against implementation plans, returns pull requests.

## Key Files

- `factory` — main CLI entry point (bash). All commands: plan, launch, auth, run, status, logs, teardown
- `lib/cloud-init.sh.tpl` — droplet bootstrap template. Secrets injected via sed at launch time.
- `prds/` — product requirement documents (committed, human-written)
- `plans/` — generated implementation plans (gitignored, machine-generated)
- `.env` — secrets (gitignored). Copy from `.env.example`.

## How It Works

1. `factory plan` runs Claude locally (read-only) to generate a plan from a PRD
2. `factory launch` creates a DO droplet via doctl, injects secrets via cloud-init
3. `factory auth` opens an SSH tunnel so user can complete Claude OAuth in their browser
4. `factory run` uploads the plan and kicks off `claude -p` in the background
5. Agent works autonomously, creates a PR, droplet self-destructs

## Development Notes

- Cloud-init has a 64KB limit. Keep the template lean.
- Secrets go in .env, never hardcode them
- The droplet self-destructs via DO API on agent exit (trap EXIT in agent-run.sh)
- Auth uses Max subscription via SSH port forwarding, not API keys
