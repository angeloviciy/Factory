# Factory Setup

## 1. DigitalOcean Account

Sign up at [digitalocean.com](https://www.digitalocean.com/) if you don't have an account.

### API Token

1. Go to **API** > **Tokens** in the [DO dashboard](https://cloud.digitalocean.com/account/api/tokens)
2. Click **Generate New Token**
3. Name it `factory` (or whatever you like)
4. Select **Full Access** (read + write) — needed for droplet creation and self-destruct
5. Copy the token (starts with `dop_v1_`)
6. Paste it into `.env` as `DO_API_TOKEN`

### SSH Key

Factory needs your SSH key registered with DigitalOcean so you can SSH into droplets for Claude OAuth.

1. If you don't have a key yet: `ssh-keygen -t ed25519`
2. Upload your public key to DO:
   ```bash
   doctl compute ssh-key import factory-key --public-key-file ~/.ssh/id_ed25519.pub
   ```
3. Get your key's fingerprint:
   ```bash
   doctl compute ssh-key list
   ```
4. Paste the fingerprint into `.env` as `DO_SSH_KEY_FINGERPRINT`

## 2. GitHub Personal Access Token

Factory uses `gh` (GitHub CLI) on the droplet to clone repos and create PRs.

1. Go to [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
2. Select **Fine-grained token**
3. Set expiration to 90 days (or your preference)
4. Under **Repository access**, select the repos you want Factory to work on (or "All repositories")
5. Under **Permissions**, grant:
   - **Contents**: Read and write (clone + push)
   - **Pull requests**: Read and write (create PRs)
   - **Metadata**: Read-only (required)
6. Generate and copy the token (starts with `github_pat_`)
7. Paste it into `.env` as `GH_TOKEN`

## 3. Local Tools

Install these on your Mac:

```bash
# DigitalOcean CLI
brew install doctl

# Authenticate doctl with your API token
doctl auth init
# Paste your DO_API_TOKEN when prompted

# Claude Code (you should already have this)
# Verify: claude --version
```

## 4. Claude Code Max Subscription

Factory uses your existing Claude Code Max subscription on the droplet. No API key needed.

Authentication happens via SSH tunnel — when you run `factory auth <ip>`, you'll:
1. SSH into the droplet with port forwarding
2. Run `claude` which prints an OAuth URL
3. Open that URL in your local browser
4. Sign in — the callback flows through the SSH tunnel back to the droplet
5. Auth persists for the session. Takes ~60 seconds.

## 5. Configure .env

```bash
cd Factory
cp .env.example .env
```

Edit `.env` and fill in your values:

| Variable | Where to find it |
|----------|-----------------|
| `DO_API_TOKEN` | DO dashboard > API > Tokens |
| `DO_SSH_KEY_FINGERPRINT` | `doctl compute ssh-key list` |
| `GH_TOKEN` | GitHub > Settings > Developer > Fine-grained tokens |
| `DEFAULT_REPO` | Your GitHub `owner/repo` |
| `DO_REGION` | `nyc1` is fine for US East. Run `doctl compute region list` for options |
| `DO_SIZE` | `s-2vcpu-4gb` ($0.036/hr). Run `doctl compute size list` for options |

## 6. Verify

```bash
# Check doctl works
doctl account get

# Check you can list SSH keys
doctl compute ssh-key list

# Check GitHub token works
GH_TOKEN=$(grep GH_TOKEN .env | cut -d= -f2) gh auth status

# You're ready
./factory status
```

## Security Notes

- `.env` is gitignored — never commit it
- Secrets are injected into droplets via cloud-init user-data. This is readable from the droplet's metadata endpoint (169.254.169.254) but only by processes running on the droplet itself. Acceptable for ephemeral VMs that self-destruct.
- GH_TOKEN scope should be as narrow as possible — only the repos you need
- DO_API_TOKEN has full access. If compromised, revoke it immediately at the DO dashboard.
- Droplets self-destruct after the agent run completes. `factory teardown` is a safety net for orphans.
