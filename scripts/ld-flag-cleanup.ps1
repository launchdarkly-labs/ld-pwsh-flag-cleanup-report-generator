<# 
.SYNOPSIS
  Generate a LaunchDarkly flag cleanup report (and optional actions).
.DESCRIPTION
  - Enumerates flags in the given project(s) and env(s)
  - Computes cleanup candidates using rules in cleanup-rules.yaml
  - Writes JSON + CSV artifacts
  - Optionally performs actions (tag/deprecate/archive) when -ApplyChanges is set
#>

param(
  [Parameter(Mandatory=$false)][string[]]$Projects,
  [Parameter(Mandatory=$false)][string[]]$Environments,
  [string]$ConfigFile,
  [string]$RulesPath = "./config/cleanup-rules.yaml",
  [string]$OutDir = "./artifacts"
)

$ErrorActionPreference = "Stop"

# Set up logging - PowerShell's built-in -Verbose parameter automatically sets $VerbosePreference

# Validate inputs - either ConfigFile or Projects/Environments must be provided
if ($ConfigFile) {
    if ($Projects -or $Environments) {
        throw "Cannot specify both ConfigFile and Projects/Environments parameters. Use either ConfigFile OR Projects/Environments."
    }
} else {
    if (-not $Projects -or $Projects.Count -eq 0) {
        throw "Either ConfigFile parameter or Projects parameter must be specified"
    }
    if (-not $Environments -or $Environments.Count -eq 0) {
        throw "Either ConfigFile parameter or Environments parameter must be specified"
    }
}

# Validate token
$token = $env:LD_ACCESS_TOKEN
if (-not $token) { 
    throw "LD_ACCESS_TOKEN environment variable is not set. Please set it with a valid LaunchDarkly API token."
}
if ($token.Length -lt 20) {
    throw "LD_ACCESS_TOKEN appears to be invalid (too short). Please check your token."
}

Write-Host "Starting LaunchDarkly flag cleanup process..."
if ($ConfigFile) {
    Write-Host "Configuration file: $ConfigFile"
} else {
    Write-Host "Projects: $($Projects -join ', ')"
    Write-Host "Environments: $($Environments -join ', ')"
}
Write-Host "Rules path: $RulesPath"
Write-Host "Output directory: $OutDir"

try {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Write-Verbose "Created output directory: $OutDir"
}
catch {
    Write-Error "Failed to create output directory '$OutDir': $($_.Exception.Message)"
    throw
}

. "$PSScriptRoot/ld-helpers.ps1"

function Load-ProjectConfig {
    param([string]$ConfigFilePath)
    
    if (-not (Test-Path $ConfigFilePath)) {
        throw "Configuration file not found: $ConfigFilePath"
    }
    
    try {
        $configContent = Get-Content $ConfigFilePath -Raw
        $config = $configContent | ConvertFrom-Json
        
        # Validate required fields
        if (-not $config.projects) {
            throw "Configuration file must contain 'projects' array"
        }
        
        if ($config.projects.Count -eq 0) {
            throw "Configuration file must contain at least one project"
        }
        
        # Validate each project
        foreach ($project in $config.projects) {
            if (-not $project.projectKey) {
                throw "Each project must have a 'projectKey' field"
            }
            if (-not $project.environments) {
                throw "Each project must have an 'environments' array"
            }
            if ($project.environments.Count -eq 0) {
                throw "Each project must have at least one environment"
            }
        }
        
        Write-Verbose "Loaded configuration with $($config.projects.Count) projects"
        return $config
    }
    catch {
        throw "Failed to load configuration file '$ConfigFilePath': $($_.Exception.Message)"
    }
}

function Process-Flag {
    param($Flag, $StatusLookup, $Project, $Env, $Rules, $Purpose)
    
    # Handle both single environment and multi-environment cases
    if ($Env -is [array]) {
        $envString = $Env -join ","
        $st = $StatusLookup
    } else {
        $envString = $Env
        $st = $StatusLookup[$Flag.key]
        if (-not $st) {
            Write-Warning "No status found for flag $($Flag.key) in $Project/$Env"
            $st = @{ status = "unknown"; lastRequested = $null }
        }
    }
    
    # Extract code references from the flag response
    $hasCodeRefs = $false
    if ($Flag.codeReferences -and $Flag.codeReferences.items -and $Flag.codeReferences.items.Count -gt 0) {
        $hasCodeRefs = $true
        Write-Verbose "Flag $($Flag.key) has $($Flag.codeReferences.items.Count) code references"
    } else {
        Write-Verbose "Flag $($Flag.key) has no code references"
    }
    
    $ctx = [pscustomobject]@{
        Project        = $Project
        Environment    = $envString
        Key            = $Flag.key
        Name           = $Flag.name
        Archived       = [bool]$Flag.archived
        Status         = $st.status
        LastRequested  = $st.lastRequested
        CreatedDate    = $Flag.creationDate
        FlagType       = if ($Flag.temporary) { "temporary" } else { "permanent" }
        Variations     = $Flag.variations
        Tags           = $Flag.tags
        HasCodeRefs    = $hasCodeRefs
    }

    $decision = Evaluate-Flag -Context $ctx -Rules $Rules -Purpose $Purpose
    
    # Debug output for first N flags (controlled by printDebugLogs config)
    $debugCount = if ($Rules.printDebugLogs) { $Rules.printDebugLogs } else { 0 }
    if ($debugCount -gt 0 -and $script:processedFlags -lt $debugCount) {
        Write-Host "DEBUG Flag: $($Flag.key) ($Purpose)"
        Write-Host "  Status: $($ctx.Status)"
        Write-Host "  FlagType: $($ctx.FlagType)"
        Write-Host "  Created: $($ctx.CreatedDate) ($($decision.createdDays) days ago)"
        Write-Host "  LastRequested: $($ctx.LastRequested) ($($decision.lastRequestedDays) days ago)"
        Write-Host "  HasCodeRefs: $($ctx.HasCodeRefs)"
        Write-Host "  Ready for code removal: $($decision.readyForCodeRemoval)"
        Write-Host "  Ready for archival: $($decision.readyForArchival)"
        Write-Host "  Reasons: $($decision.reasons -join '; ')"
        Write-Host ""
    }
    
    return $decision
}

# Check ldcli availability and use it if possible
# Initialize script-scoped variables
$script:processedFlags = 0

$useLdCli = Test-LdCli
if ($useLdCli) {
    Write-Host "ldcli is available and will be used for data fetching"
} else {
    Write-Host "ldcli not found, using REST API"
}

$headers = @{ Authorization = $token }
Write-Verbose "API headers configured"

# Load configuration
if ($ConfigFile) {
    try {
        $config = Load-ProjectConfig -ConfigFilePath $ConfigFile
        
        # Override settings from config if provided
        if ($config.globalSettings) {
            if ($config.globalSettings.rulesPath) {
                $RulesPath = $config.globalSettings.rulesPath
            }
            if ($config.globalSettings.outputDirectory) {
                $OutDir = $config.globalSettings.outputDirectory
            }
        }
        
        Write-Verbose "Configuration loaded successfully"
    }
    catch {
        Write-Error "Failed to load configuration: $($_.Exception.Message)"
        throw
    }
}

# Load rules (defaults if missing)
try {
    $rules = Load-Rules -Path $RulesPath
    Write-Verbose "Rules loaded successfully"
}
catch {
    Write-Error "Failed to load rules: $($_.Exception.Message)"
    throw
}

# Collect and evaluate
$candidates = New-Object System.Collections.ArrayList
$totalFlags = 0
$processedFlags = 0

# Determine projects and environments to process
if ($ConfigFile) {
    $projectsToProcess = $config.projects
    Write-Host "Processing $($projectsToProcess.Count) projects from configuration file"
} else {
    # Convert command-line parameters to the same format as JSON config
    $projectsToProcess = @()
    foreach ($project in $Projects) {
        $projectsToProcess += [pscustomobject]@{
            projectKey = $project
            environments = $Environments
        }
    }
    Write-Host "Processing $($projectsToProcess.Count) projects from command line"
}

foreach ($projectConfig in $projectsToProcess) {
    $project = $projectConfig.projectKey
    $environments = $projectConfig.environments
    
    Write-Host "Processing project: $project"
    
    # Collect all flag data across environments for this project
    $projectFlags = @{}
    $projectStatuses = @{}
    
    foreach ($env in $environments) {
        Write-Host "  Processing environment: $env"
        
        try {
            # Fetch flags for both purposes and flag statuses
            $codeRemovalFlags = Get-FlagsForPurpose -Project $project -Env $env -Rules $rules -Purpose "codeRemoval"
            $archivalFlags = Get-FlagsForPurpose -Project $project -Env $env -Rules $rules -Purpose "archival"
            $statuses = Get-FlagStatuses -Project $project -Env $env
            
            # Combine all flags and store by flag key
            $flags = $codeRemovalFlags + $archivalFlags
            
            Write-Host "    Found $($flags.Count) flags in $project/$env"
            
            # Store flags by key (avoid duplicates across environments)
            foreach ($flag in $flags) {
                if (-not $projectFlags.ContainsKey($flag.key)) {
                    $projectFlags[$flag.key] = $flag
                }
            }
            
            # Store statuses by flag key and environment
            foreach ($s in $statuses) { 
                # Extract flag key from the parent href
                $flagKey = ($s._links.parent.href -split '/')[-1]
                if (-not $projectStatuses.ContainsKey($flagKey)) {
                    $projectStatuses[$flagKey] = @{}
                }
                $projectStatuses[$flagKey][$env] = @{
                    status = $s.name
                    lastRequested = $s.lastRequested
                }
            }
        }
        catch {
            Write-Error "Failed to process project '$project' environment '$env': $($_.Exception.Message)"
            # Continue with other environments
        }
    }
    
    # Process flags for this project using aggregated data
    Write-Host "  Processing $($projectFlags.Count) unique flags across $($environments.Count) environments"
    
    foreach ($flagKey in $projectFlags.Keys) {
        $flag = $projectFlags[$flagKey]
        
        try {
            # Create aggregated status lookup for this flag
            $aggregatedStatus = @{
                status = "unknown"
                lastRequested = $null
                environments = $projectStatuses[$flagKey]
            }
            
            # Aggregate status across environments
            if ($projectStatuses.ContainsKey($flagKey)) {
                $envStatuses = $projectStatuses[$flagKey]
                $statuses = $envStatuses.Values | Where-Object { $_.status }
                $lastRequestedDates = $envStatuses.Values | Where-Object { $_.lastRequested } | ForEach-Object { $_.lastRequested }
                
                # Determine overall status - if any environment is 'launched', flag is considered launched
                # If all are 'inactive', flag is inactive
                if ($statuses | Where-Object { $_.status -eq "launched" }) {
                    $aggregatedStatus.status = "launched"
                } elseif ($statuses | Where-Object { $_.status -eq "inactive" }) {
                    $aggregatedStatus.status = "inactive"
                } else {
                    $aggregatedStatus.status = ($statuses | Select-Object -First 1).status
                }
                
                # Use the most recent lastRequested date across all environments
                if ($lastRequestedDates.Count -gt 0) {
                    $aggregatedStatus.lastRequested = $lastRequestedDates | Sort-Object -Descending | Select-Object -First 1
                }
            }
            
            # Determine purpose based on aggregated status
            # For code removal: status should be 'launched' (serving same variation to everyone)
            # For archival: status should be 'inactive' (not serving any traffic)
            $purpose = if ($aggregatedStatus.status -eq "launched") { "codeRemoval" } else { "archival" }
            
            Write-Verbose "Processing flag: $($flag.key) (aggregated across $($environments.Count) environments, status: $($aggregatedStatus.status), purpose: $purpose)"
            $decision = Process-Flag -Flag $flag -StatusLookup $aggregatedStatus -Project $project -Env $environments -Rules $rules -Purpose $purpose
            [void]$candidates.Add($decision)
            $script:processedFlags++
        }
        catch {
            Write-Warning "Failed to process flag $($flag.key): $($_.Exception.Message)"
        }
    }
    
    $totalFlags += $projectFlags.Count
}

Write-Host "Processing complete. Total flags processed: $processedFlags/$totalFlags"

# Persist artifacts
try {
    $reportJson = Join-Path $OutDir "ld-cleanup-report.json"
    $reportCsv  = Join-Path $OutDir "ld-cleanup-report.csv"
    
    Write-Verbose "Writing JSON report to: $reportJson"
    $candidates | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $reportJson
    
    Write-Verbose "Writing CSV report to: $reportCsv"
    $candidates | Export-Csv -NoTypeInformation -Encoding utf8 $reportCsv

    Write-Host "Artifacts generated successfully:"
    Write-Host "  $reportJson"
    Write-Host "  $reportCsv"
}
catch {
    Write-Error "Failed to generate artifacts: $($_.Exception.Message)"
    throw
}

# Optional actions
if ($ApplyChanges) {
    Write-Host "Applying changes (not a dry run)..."
    
    $toArchive   = $candidates | Where-Object { $_.ActionsToApply -contains "archive" }
    $toTag       = $candidates | Where-Object { $_.ActionsToApply -contains "tag" }
    $toDeprecate = $candidates | Where-Object { $_.ActionsToApply -contains "deprecate" }

    Write-Host "Actions to apply:"
    Write-Host "  Tag: $($toTag.Count) flags"
    Write-Host "  Deprecate: $($toDeprecate.Count) flags"
    Write-Host "  Archive: $($toArchive.Count) flags"

    $actionErrors = 0
    
    foreach ($item in $toTag) {
        try {
            Set-FlagTags -Base $LdApiBase -Headers $headers -Item $item -AddTag $rules.actions.tagName
            Write-Verbose "Tagged flag: $($item.key)"
        }
        catch {
            Write-Warning "Failed to tag flag $($item.key): $($_.Exception.Message)"
            $actionErrors++
        }
    }
    
    foreach ($item in $toDeprecate) {
        try {
            Patch-FlagDeprecated -Base $LdApiBase -Headers $headers -Item $item -Deprecated $true
            Write-Verbose "Deprecated flag: $($item.key)"
        }
        catch {
            Write-Warning "Failed to deprecate flag $($item.key): $($_.Exception.Message)"
            $actionErrors++
        }
    }
    
    foreach ($item in $toArchive) {
        try {
            Archive-Flag -Base $LdApiBase -Headers $headers -Item $item
            Write-Verbose "Archived flag: $($item.key)"
        }
        catch {
            Write-Warning "Failed to archive flag $($item.key): $($_.Exception.Message)"
            $actionErrors++
        }
    }
    
    if ($actionErrors -gt 0) {
        Write-Warning "$actionErrors actions failed. Check logs for details."
    } else {
        Write-Host "All actions completed successfully."
    }
}

# Optional PR summary
# Generate PR summary for GitHub Actions
try {
    $summaryPath = Join-Path $OutDir "pr-summary.txt"
    New-PrSummary -Candidates $candidates -Rules $rules -OutPath $summaryPath
    Write-Host "PR summary: $summaryPath"
}
catch {
    Write-Warning "Failed to generate PR summary: $($_.Exception.Message)"
}

# Summary statistics
$readyForCodeRemoval = ($candidates | Where-Object { $_.readyForCodeRemoval }).Count
$readyForArchival = ($candidates | Where-Object { $_.readyForArchival }).Count

Write-Host "Summary:"
Write-Host "  Total flags processed: $script:processedFlags"
Write-Host "  Ready for code removal: $readyForCodeRemoval"
Write-Host "  Ready for archival: $readyForArchival"

# Exit code: non-zero if we *want* to draw attention (e.g., candidates found) but don't fail the build by default.
exit 0
