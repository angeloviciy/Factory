# Factory

Automated cloud development agents. Spin up ephemeral DigitalOcean VMs, run Claude Code autonomously against a plan, and get back a pull request.

Inspired by Michael Truell's "third era" of software development — developers as architects, agents as builders.

## How it works

1. **Plan locally** — write a PRD, then use Claude to generate a step-by-step implementation plan on your Mac (free, read-only)
2. **Launch a droplet** — Factory spins up a DigitalOcean VM, clones your repo, installs deps
3. **Authenticate once** — SSH in, complete Claude OAuth via browser tunnel (~60 seconds)
4. **Run the agent** — Claude Code executes your plan autonomously on the droplet
5. **Review the PR** — agent opens a pull request with its changes, then the droplet self-destructs

## Commands

```
factory plan <prd-file>                   Generate an implementation plan from a PRD
factory launch [--repo] [--branch]        Create and bootstrap a droplet
factory auth <droplet-ip>                 SSH tunnel for Claude OAuth
factory run <droplet-ip> <plan-file>      Ship plan to droplet, start autonomous agent
factory status                            List running factory droplets
factory teardown [--all]                  Destroy orphaned droplets
```

## Quick Reference

| Command | Description |
|---------|-------------|
| `factory plan` | Generate an implementation plan from a PRD |
| `factory launch` | Create and bootstrap a DigitalOcean droplet |
| `factory auth` | Open SSH tunnel for Claude OAuth |
| `factory run` | Ship a plan to a droplet and start the autonomous agent |
| `factory status` | List running factory droplets |
| `factory logs` | Stream logs from a running droplet |
| `factory teardown` | Destroy orphaned droplets |

## Setup

See [SETUP.md](SETUP.md) for prerequisites and configuration.
