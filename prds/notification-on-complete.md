# PRD: Agent Completion Notifications

## Problem
After running `factory run`, you have no idea when the agent finishes unless you're actively tailing logs. The droplet self-destructs silently, and you have to notice the PR on GitHub yourself.

## Goal
When the agent finishes (success or failure), notify the user on their Mac so they can go review the PR.

## Requirements

### 1. Droplet-side: POST a webhook on completion
- Before self-destructing, the agent should POST a JSON payload to a configurable webhook URL
- Payload should include: repo, branch, PR URL (if created), status (success/failure), duration, droplet name
- The webhook URL comes from an env var `FACTORY_WEBHOOK_URL` (injected via cloud-init like other secrets)
- Use ntfy.sh as the default — it's free, no signup, just POST to a topic URL
- If no webhook URL is set, skip silently (don't break the flow)

### 2. Local: `factory notify-setup` command
- Generates a random ntfy.sh topic name (e.g. `factory-a8f3b2`)
- Prints instructions to subscribe: open `https://ntfy.sh/factory-a8f3b2` in browser or install the ntfy app
- Writes `FACTORY_WEBHOOK_URL=https://ntfy.sh/factory-a8f3b2` to `.env`

### 3. Update cloud-init template
- Inject `FACTORY_WEBHOOK_URL` into the droplet alongside other secrets
- Pass it through to `agent-run.sh`

## Constraints
- No new dependencies on the droplet (just `curl`)
- No new dependencies locally
- ntfy.sh is free and requires no auth — just POST to a URL
- Keep it simple: one curl call, not a notification framework

## Out of Scope
- Slack/Discord/email integrations (can add later)
- Rich notification formatting
- Retry logic if the webhook fails
