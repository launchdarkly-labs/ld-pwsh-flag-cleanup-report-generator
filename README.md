# LaunchDarkly Flag Cleanup

A PowerShell script that identifies LaunchDarkly feature flags ready for code removal or archival based on configurable rules. Designed for GitHub Actions integration.

## Input

The script accepts either command-line parameters or a JSON configuration file:

### Command Line Parameters
```powershell
pwsh ./scripts/ld-flag-cleanup.ps1 -Projects "project1,project2" -Environments "production,staging" -Verbose
```

**Command Line Limitation:** When using command-line parameters, all specified environments are applied to all specified projects. 

### JSON Configuration File (Recommended for multi-project/environment usage)
```powershell
pwsh ./scripts/ld-flag-cleanup.ps1 -ConfigFile "./config/projects-config.json" -Verbose
```

**JSON Configuration Format:**
```json
{
  "projects": [
    {
      "projectKey": "web-platform",
      "environments": ["production", "staging", "development"]
    },
    {
      "projectKey": "mobile-app",
      "environments": ["production", "staging"]
    }
  ],
  "globalSettings": {
    "rulesPath": "./config/cleanup-rules.yaml",
    "outputDirectory": "./artifacts"
  }
}
```

**Reference Example:** See `config/proj-env-config-example.json` for an example.

## Configuration Rules

Edit `config/cleanup-rules.yaml` to customize cleanup criteria:

```yaml
# Time-based thresholds
daysSinceLastEvaluation: 7      # <number> flags with no evaluations in past N days
daysSinceCreation: 30           # <number> flags created more than N days ago

# Flag requirements
checkForCodeReferences: true    # <boolean> whether to check for existence of flags' code references
checkForFlagType: true          # <boolean> whether to consider the flag type (temporary/permanent)
checkForFlagStatus: true        # <boolean> whether to check the flag status (new/active/launched/inactive)

# Debug output
printDebugLogs: 3               # <number> whether the print debug logs + a number of flags to show debug info for (0 = no debug logs)
```

## Cleanup Criteria

### Ready for Code Removal
- Created more than X days ago
- Has evaluations in the past Y days
- Flag type = temporary (if enabled)
- Flag status = launched (if enabled)
- Has code references (if enabled)

**Example ldcli command for code removal flags:**
```bash
ldcli flags list \
  --project "your-project-key" \
  --env "production" \
  --expand "codeReferences,evaluation" \
  --filter "filterEnv:production,creationDate:{\"before\":1756047090193},type:temporary,evaluated:{\"after\":1755442290193}" \
  --limit 100 \
  -o json
```

### Ready for Archival
- Created more than X days ago
- No evaluations in the past Y days
- Flag type = temporary (if enabled)
- Flag status = inactive (if enabled)
- No code references (if enabled)

**Example ldcli command for archival flags:**
```bash
ldcli flags list \
  --project "your-project-key" \
  --env "production" \
  --expand "codeReferences,evaluation" \
  --filter "filterEnv:production,creationDate:{\"before\":1756047090193},type:temporary" \
  --limit 100 \
  -o json
```

**Note:** The timestamps in the examples are dynamically calculated based on your `daysSinceCreation` and `daysSinceLastEvaluation` rules. The script handles this automatically.

## Multi-Environment Aggregation

When multiple environments are specified for a project, the script aggregates data across all environments:
- **Status**: Flag is considered "launched" if any environment is launched, "inactive" if all are inactive
- **Last Requested**: Uses the most recent evaluation date across all environments
- **Code References**: Flag has code references if any environment shows references

## Output

The script generates three files in the artifacts directory:

### JSON Report (`ld-cleanup-report.json`)
Detailed machine-readable report with all flag data and decisions.

### CSV Report (`ld-cleanup-report.csv`)
Tabular format for analysis and filtering.

### PR Summary (`pr-summary.txt`)
Markdown summary suitable for GitHub PR comments, grouped by project.

## Prerequisites

- PowerShell 7.0+
- LaunchDarkly API Access Token (set as `LD_ACCESS_TOKEN` environment variable)
- LaunchDarkly CLI

## GitHub Actions Integration

### Prerequisites

**Required:** Set up the LaunchDarkly API token as a repository secret:

1. Go to your repository → Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Name: `LD_ACCESS_TOKEN`
4. Value: Your LaunchDarkly API token (starts with `api-`)

### Basic Workflow

```yaml
name: LaunchDarkly Flag Cleanup

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  ld-cleanup:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write  # Required to post PR comments
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup PowerShell
        uses: PowerShell/PowerShell@v1
        with:
          pwsh-version: '7.4.x'
      
      - name: Install LaunchDarkly CLI
        run: npm install -g @launchdarkly/ldcli
      
      - name: Run cleanup
        env:
          LD_ACCESS_TOKEN: ${{ secrets.LD_ACCESS_TOKEN }}
        run: |
          pwsh ./scripts/ld-flag-cleanup.ps1 `
            -ConfigFile "./config/projects-config.json" `
            -Verbose
      
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: ld-cleanup-report
          path: artifacts/*
      
      - name: Comment PR summary
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const body = fs.readFileSync('artifacts/pr-summary.txt', 'utf8');
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body
            });
```

### Alternative: Command-line Parameters

```yaml
      - name: Run cleanup
        env:
          LD_ACCESS_TOKEN: ${{ secrets.LD_ACCESS_TOKEN }}
        run: |
          pwsh ./scripts/ld-flag-cleanup.ps1 `
            -Projects "web,api" `
            -Environments "staging,production" `
            -Verbose
```

**Note:** Command-line approach applies all environments to all projects (see limitations above).

## Troubleshooting

**Authentication Error:**
```
Error: LD_ACCESS_TOKEN is not set
```
Set your API token: `$env:LD_ACCESS_TOKEN = "your-token"`

**Configuration Error:**
```
Error: Failed to load configuration file
```
Check JSON syntax and file permissions

**No Flags Found:**
```
Processing complete. Total flags processed: 0/0
```
Verify project keys and environment names are correct