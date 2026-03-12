#!/bin/bash
set -euo pipefail

# cloud-init doesn't always set HOME
export HOME="/root"

# === Injected by factory launch ===
DO_API_TOKEN="__DO_API_TOKEN__"
GH_TOKEN="__GH_TOKEN__"
REPO="__REPO__"
BRANCH="__BRANCH__"
SETUP_CMD="__SETUP_CMD__"
FACTORY_WEBHOOK_URL="__FACTORY_WEBHOOK_URL__"

# === Self-destruct on any exit (safety net for bootstrap failures) ===
DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)

self_destruct() {
    echo "[factory] Self-destructing droplet $DROPLET_ID..."
    curl -s -X DELETE \
        -H "Authorization: Bearer $DO_API_TOKEN" \
        "https://api.digitalocean.com/v2/droplets/$DROPLET_ID"
}

# === Create non-root user (Claude Code refuses --dangerously-skip-permissions as root) ===
useradd -m -s /bin/bash factory
echo "factory ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/factory

FACTORY_HOME="/home/factory"

# === Write secrets ===
cat > "$FACTORY_HOME/.secrets" <<SECRETS
export GH_TOKEN="$GH_TOKEN"
export DO_API_TOKEN="$DO_API_TOKEN"
export FACTORY_WEBHOOK_URL="$FACTORY_WEBHOOK_URL"
SECRETS
chmod 600 "$FACTORY_HOME/.secrets"
chown factory:factory "$FACTORY_HOME/.secrets"

# === Install system dependencies ===
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq unzip > /dev/null 2>&1

# Install GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update -qq && apt-get install -y -qq gh > /dev/null 2>&1

# Install Node.js (for Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs > /dev/null 2>&1

# Install Claude Code
npm install -g @anthropic-ai/claude-code > /dev/null 2>&1

# === Configure git (as factory user) ===
su - factory -c 'git config --global user.name "Factory Agent"'
su - factory -c 'git config --global user.email "factory@noreply.github.com"'

# === Authenticate GitHub (as factory user) ===
su - factory -c "echo '$GH_TOKEN' | gh auth login --with-token"
su - factory -c "gh auth setup-git"

# === Clone repo (as factory user) ===
su - factory -c "gh repo clone '$REPO' '$FACTORY_HOME/repo'"
if [ "$BRANCH" != "main" ] && [ "$BRANCH" != "" ]; then
    su - factory -c "cd '$FACTORY_HOME/repo' && git checkout -b '$BRANCH'"
fi

# === Run setup command (if provided) ===
if [ -n "$SETUP_CMD" ] && [ "$SETUP_CMD" != "__SETUP_CMD__" ]; then
    echo "[factory] Running setup: $SETUP_CMD"
    su - factory -c "cd '$FACTORY_HOME/repo' && $SETUP_CMD"
fi

# === Write the agent runner script ===
cat > "$FACTORY_HOME/agent-run.sh" <<'AGENT'
#!/bin/bash
set -euo pipefail
source ~/.secrets

DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)

self_destruct() {
    echo "[factory] Self-destructing droplet $DROPLET_ID..."
    curl -s -X DELETE \
        -H "Authorization: Bearer $DO_API_TOKEN" \
        "https://api.digitalocean.com/v2/droplets/$DROPLET_ID"
}

generate_summary() {
    local log_file="$HOME/agent.log"
    local summary_file="$HOME/summary.md"
    local branch="$1"
    local repo="$2"

    if [ ! -s "$log_file" ]; then
        cat > "$summary_file" <<SUMMARY
# Factory Run Summary

**Status**: failure
**Error**: Agent failed before producing output

## Startup Log
\`\`\`
$(cat "$HOME/agent-startup.log" 2>/dev/null || echo "No startup log available")
\`\`\`
SUMMARY
        echo "failure"
        return
    fi

    # Parse the result line (last line with type=result)
    local result_line
    result_line=$(jq -r 'select(.type == "result")' "$log_file" 2>/dev/null | tail -1)

    local status="failure"
    local duration_ms=""
    local duration_fmt="unknown"
    local cost="unknown"
    local turns="unknown"
    local model="unknown"

    if [ -n "$result_line" ]; then
        local is_error
        is_error=$(echo "$result_line" | jq -r '.is_error // false')
        if [ "$is_error" = "false" ]; then
            status="success"
        fi

        duration_ms=$(echo "$result_line" | jq -r '.duration_ms // empty')
        if [ -n "$duration_ms" ]; then
            local secs=$((duration_ms / 1000))
            local mins=$((secs / 60))
            local remaining_secs=$((secs % 60))
            duration_fmt="${mins}m ${remaining_secs}s"
        fi

        cost=$(echo "$result_line" | jq -r '.total_cost_usd // "unknown"')
        turns=$(echo "$result_line" | jq -r '.num_turns // "unknown"')
    fi

    # Extract model from init/system line
    model=$(jq -r 'select(.type == "system") | .model // empty' "$log_file" 2>/dev/null | head -1)
    if [ -z "$model" ]; then
        model="unknown"
    fi

    # Files modified and commit count
    local files_modified=""
    local commit_count="0"
    if git -C "$HOME/repo" rev-parse HEAD >/dev/null 2>&1; then
        files_modified=$(git -C "$HOME/repo" diff --name-only "origin/$branch" "$branch" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
        commit_count=$(git -C "$HOME/repo" rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
    fi

    cat > "$summary_file" <<SUMMARY
# Factory Run Summary

- **Status**: $status
- **Duration**: $duration_fmt
- **Cost**: \$$cost
- **Turns**: $turns
- **Model**: $model
- **Files modified**: ${files_modified:-none}
- **Commits**: $commit_count
- **Repo**: $repo
- **Branch**: $branch
SUMMARY

    # Write sourceable env file for use by on_exit
    cat > "$HOME/summary.env" <<ENV
SUMMARY_STATUS=$status
SUMMARY_DURATION=$duration_fmt
SUMMARY_COST=$cost
SUMMARY_TURNS=$turns
SUMMARY_MODEL=$model
SUMMARY_FILES=${files_modified:-none}
SUMMARY_COMMITS=$commit_count
ENV

    echo "$status"
}

on_exit() {
    set +e

    echo "[factory] Running on_exit cleanup..."

    cd ~/repo 2>/dev/null || true
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local repo
    repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||' || echo "unknown")

    # 1. Generate summary
    echo "[factory] Generating summary..."
    local status
    status=$(generate_summary "$branch" "$repo") || true

    # 2. Create gist with full log + summary
    echo "[factory] Creating gist..."
    local gist_url=""
    local gist_files=""
    if [ -f "$HOME/summary.md" ]; then
        gist_files="$HOME/summary.md"
    fi
    if [ -f "$HOME/agent.log" ]; then
        gist_files="$gist_files $HOME/agent.log"
    fi
    if [ -f "$HOME/plan.md" ]; then
        gist_files="$gist_files $HOME/plan.md"
    fi
    if [ -n "$gist_files" ]; then
        gist_url=$(gh gist create $gist_files \
            --desc "Factory run: $repo $branch — $status" \
            2>/dev/null | tail -1) || true
    fi
    echo "[factory] Gist: ${gist_url:-not created}"

    # 3. Comment on PR (if it exists)
    echo "[factory] Checking for PR..."
    local pr_number=""
    local pr_url=""
    pr_number=$(gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null) || true
    if [ -n "$pr_number" ]; then
        pr_url=$(gh pr view "$pr_number" --json url --jq '.url' 2>/dev/null) || true

        source "$HOME/summary.env" 2>/dev/null || true

        local pr_comment="## Factory Run Summary
- **Status**: ${SUMMARY_STATUS:-$status}
- **Duration**: ${SUMMARY_DURATION:-unknown}
- **Cost**: \$${SUMMARY_COST:-unknown}
- **Turns**: ${SUMMARY_TURNS:-unknown}
- **Model**: ${SUMMARY_MODEL:-unknown}
- **Files modified**: ${SUMMARY_FILES:-unknown}
- **Commits**: ${SUMMARY_COMMITS:-unknown}

[Full agent log](${gist_url:-})"

        gh pr comment "$pr_number" --body "$pr_comment" 2>/dev/null || true
        echo "[factory] Commented on PR #$pr_number"
    fi

    # 4. Send ntfy notification
    if [ -n "${FACTORY_WEBHOOK_URL:-}" ]; then
        echo "[factory] Sending ntfy notification..."
        source "$HOME/summary.env" 2>/dev/null || true

        local ntfy_body="Branch: $branch | Duration: ${SUMMARY_DURATION:-unknown} | Cost: \$${SUMMARY_COST:-unknown}"
        if [ -n "$gist_url" ]; then
            ntfy_body="$ntfy_body | $gist_url"
        fi
        if [ "$status" = "success" ] && [ -n "$pr_url" ]; then
            ntfy_body="$ntfy_body | PR: $pr_url"
        fi

        curl -s \
            -H "Title: Factory: $status — $repo" \
            -d "$ntfy_body" \
            "$FACTORY_WEBHOOK_URL" >/dev/null 2>&1 || true
        echo "[factory] Notification sent"
    fi

    # 5. Self-destruct
    echo "[factory] Done. Droplet will self-destruct."
    self_destruct || true
}

trap on_exit EXIT

cd ~/repo

PLAN=$(cat ~/plan.md)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "[factory] Starting agent run at $(date)"
echo "[factory] Branch: $BRANCH"
echo "[factory] Plan: ~/plan.md"

claude -p "You are an autonomous coding agent. Execute the following implementation plan precisely.
Work through each step. Run tests if they exist. Commit your work as you go with clear commit messages.
Do NOT include 'Co-Authored-By' lines in any commit messages.
When done, push your branch and create a pull request.

PLAN:
$PLAN" \
    --allowedTools "Read,Edit,Write,Bash,Glob,Grep,Agent" \
    --dangerously-skip-permissions \
    --max-turns 200 \
    --output-format stream-json \
    --verbose \
    > ~/agent.log 2>&1

CLAUDE_EXIT=$?
echo "[factory] Agent finished at $(date) (exit code: $CLAUDE_EXIT)"

# Extract session ID from builder for potential resume later
SESSION_ID=$(tail -1 ~/agent.log | jq -r '.session_id // empty' 2>/dev/null || true)
if [ -z "$SESSION_ID" ]; then
    echo "[factory] Warning: Could not extract session ID from agent log"
fi

# Push and create PR if there are commits ahead of origin
PR_NUMBER=""
REPO_NAME=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
COMMITS_AHEAD=$(git rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || echo "new")
if [ "$COMMITS_AHEAD" != "0" ]; then
    git push -u origin "$BRANCH"

    PR_BODY="## Automated by Factory

This PR was generated by an autonomous Claude Code agent running on an ephemeral DigitalOcean droplet.

### Plan executed
$(cat ~/plan.md)

---
Review the changes carefully before merging."

    PR_URL=$(gh pr create \
        --title "factory: $(head -1 ~/plan.md | sed 's/^#* *//')" \
        --body "$PR_BODY" \
        2>/dev/null || echo "")

    if [ -n "$PR_URL" ]; then
        PR_NUMBER=$(echo "$PR_URL" | grep -o '[0-9]*$')
        echo "[factory] PR created: $PR_URL (PR #$PR_NUMBER)"
    else
        # PR may already exist (created by builder agent) — try to find it
        PR_NUMBER=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null || echo "")
        if [ -n "$PR_NUMBER" ]; then
            echo "[factory] Found existing PR #$PR_NUMBER for branch $BRANCH"
        else
            echo "[factory] PR could not be created or found"
        fi
    fi
fi

# === Reviewer agent phase ===
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_NAME" ]; then
    echo "[factory] Starting reviewer agent at $(date)"

    DIFF=$(git diff "origin/main..HEAD")

    claude -p "You are a code reviewer. Review the following diff against the implementation plan.

Post your review on PR #${PR_NUMBER} in the ${REPO_NAME} repository using gh api.

If you find issues, post a review with line-level comments using:
gh api repos/${REPO_NAME}/pulls/${PR_NUMBER}/reviews --method POST -f event=COMMENT -f body='Summary' --jsonc comments='[...]'

If everything looks good, post a single comment: 'LGTM — no issues found' using:
gh api repos/${REPO_NAME}/pulls/${PR_NUMBER}/reviews --method POST -f event=APPROVE -f body='LGTM — no issues found'

PLAN:
$PLAN

DIFF:
$DIFF" \
        --allowedTools "Read,Glob,Grep,Bash" \
        --dangerously-skip-permissions \
        --max-turns 30 \
        --output-format stream-json \
        --verbose \
        > ~/reviewer.log 2>&1 || true

    echo "[factory] Reviewer agent finished at $(date)"
else
    echo "[factory] Skipping reviewer: PR_NUMBER='$PR_NUMBER' REPO_NAME='${REPO_NAME:-}'"
fi

# === Builder fix pass (resumed session) ===
if [ -n "$SESSION_ID" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_NAME" ]; then
    echo "[factory] Starting fixer agent at $(date)"

    claude -p "Read the review comments on PR #${PR_NUMBER} in ${REPO_NAME} using:
gh api repos/${REPO_NAME}/pulls/${PR_NUMBER}/reviews
gh api repos/${REPO_NAME}/pulls/${PR_NUMBER}/comments

If the reviewer said LGTM or approved with no issues, do nothing.

Otherwise, fix every issue raised in the review comments. Commit and push your fixes.
Do NOT include 'Co-Authored-By' lines in any commit messages." \
        --resume "$SESSION_ID" \
        --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
        --dangerously-skip-permissions \
        --max-turns 50 \
        --output-format stream-json \
        --verbose \
        > ~/fixer.log 2>&1 || true

    echo "[factory] Fixer agent finished at $(date)"
else
    echo "[factory] Skipping fixer: SESSION_ID='${SESSION_ID:-}' PR_NUMBER='$PR_NUMBER' REPO_NAME='${REPO_NAME:-}'"
fi

echo "[factory] Agent run complete. Cleanup will run via EXIT trap."
AGENT
chmod +x "$FACTORY_HOME/agent-run.sh"
chown factory:factory "$FACTORY_HOME/agent-run.sh"

# === Signal bootstrap complete ===
touch "$FACTORY_HOME/.bootstrap-complete"
# Also touch in /root so factory launch polling still works
touch /root/.bootstrap-complete
echo "[factory] Bootstrap complete at $(date). Ready for auth + run."
