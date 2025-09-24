# LaunchDarkly Flag Cleanup

A PowerShell script that identifies LaunchDarkly feature flags ready for code removal or archival based on configurable rules. Designed for GitHub Actions integration.

## Input

The script accepts either command-line parameters or a JSON configuration file:

### Command Line Parameters
```powershell
pwsh ./scripts/ld-flag-cleanup.ps1 -Projects "project1,project2" -Environments "production,staging" -Verbose
```

### JSON Configuration File
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

## Configuration Rules

Edit `config/cleanup-rules.yaml` to customize cleanup criteria:

```yaml
# Time-based thresholds
daysSinceLastEvaluation: 7      # flags with no evaluations in past N days
daysSinceCreation: 30           # flags created more than N days ago

# Flag requirements
checkForCodeReferences: true    # whether to check for flags code references
checkForFlagType: true          # whether to check consider the flag type (temporary/permanent)
checkForFlagStatus: true        # whether to check the flag status (new/active/launched/inactive)

# Debug output
printDebugLogs: 3               # number of flags to show debug info for (0 = no debug logs)
```

## Cleanup Criteria

### Ready for Code Removal
- Flag type = temporary (if enabled)
- Flag status = launched (if enabled)
- Created more than X days ago
- Has evaluations in the past Y days
- Has code references (if enabled)

### Ready for Archival
- Flag type = temporary (if enabled)
- Flag status = inactive (if enabled)
- Created more than X days ago
- No evaluations in the past Y days
- No code references (if enabled)

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
- LaunchDarkly CLI (optional, script falls back to REST API)

## GitHub Actions Integration

```yaml
name: LaunchDarkly Flag Cleanup

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  ld-cleanup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup PowerShell
        uses: PowerShell/PowerShell@v1
        with:
          pwsh-version: '7.4.x'
      
      - name: Run cleanup
        env:
          LD_ACCESS_TOKEN: ${{ secrets.LD_ACCESS_TOKEN }}
        run: |
          pwsh ./scripts/ld-flag-cleanup.ps1 `
            -ConfigFile "./config/projects-config.json" `
            -Verbose
```

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