# Adding a New Agent

## Quick Start

The fastest way to add an agent — scaffolds files, deploys, and restarts in one command:

```bash
./scripts/add-agent.sh
```

The script prompts for an agent ID, display name, description, emoji, and color, then:
1. Creates the agent directory from this template
2. Runs envsubst and applies the agent ConfigMap
3. Registers the agent in the live gateway config
4. Syncs the config back to the ConfigMap (survives restarts)
5. Installs workspace files (AGENTS.md, agent.json)
6. Restarts the gateway

Your agent is ready to chat immediately.

### Flags

| Flag | Purpose |
|------|---------|
| `--k8s` | Use kubectl instead of oc |
| `--scaffold-only` | Create files only, don't deploy |
| `--env-file PATH` | Custom .env file |

### Non-interactive

```bash
./scripts/add-agent.sh myagent "My Agent" "Monitors API health"
```

## Manual Setup

If you prefer to do it step by step:

### 1. Copy the template

```bash
cp -r agents/openclaw/agents/_template agents/openclaw/agents/myagent
cd agents/openclaw/agents/myagent
mv agent.yaml.template myagent-agent.yaml.envsubst
```

### 2. Edit the agent files

Open `myagent-agent.yaml.envsubst` and replace all `REPLACE_` placeholders:

| Placeholder | Example | Description |
|-------------|---------|-------------|
| `REPLACE_AGENT_ID` | `myagent` | Lowercase ID (used in filenames and K8s names) |
| `REPLACE_DISPLAY_NAME` | `My Agent` | Human-readable name shown in UI |
| `REPLACE_DESCRIPTION` | `Monitors API health` | What the agent does |
| `REPLACE_EMOJI` | `🔍` | Emoji shown in UI |
| `REPLACE_COLOR` | `#FF6B6B` | Hex color for UI |

Write your agent's instructions in the `AGENTS.md` section. This is the markdown
that tells the agent who it is and what to do.

### 3. Deploy

Run `add-agent.sh` without `--scaffold-only` to deploy the already-scaffolded agent,
or deploy manually:

```bash
# Run envsubst on the template
envsubst < myagent-agent.yaml.envsubst > myagent-agent.yaml

# Apply to cluster
oc apply -f myagent-agent.yaml

# The agent also needs to be added to the live gateway config.
# The easiest way is to add it via the UI, then sync:
./scripts/sync-config.sh
```

## Adding a Scheduled Job

To give your agent a scheduled task, create a `JOB.md` in your agent's directory:

```bash
cp agents/openclaw/agents/_template/JOB.md.template \
   agents/openclaw/agents/myagent/JOB.md
```

Edit the frontmatter:

```yaml
---
id: myagent-job              # Unique job ID
schedule: "0 9 * * *"        # Cron expression (this = daily 9 AM UTC)
tz: UTC                      # Timezone
---
```

Write the job instructions in the body — this is the message your agent receives
when the job fires. Then update the running jobs:

```bash
./scripts/update-jobs.sh           # OpenShift
./scripts/update-jobs.sh --k8s     # Kubernetes
```

### Cron Schedule Examples

| Schedule | Expression |
|----------|-----------|
| Every day at 9 AM UTC | `0 9 * * *` |
| Every 8 hours | `0 */8 * * *` |
| Weekdays at 9 AM and 5 PM | `0 9,17 * * 1-5` |
| Every Monday at 8 AM | `0 8 * * 1` |
