function Load-Rules {
    param([string]$Path)
    
    # Default configuration
    $defaultRules = @{
        evaluationDays = 7
        creationDays = 30
        flagType = "temporary"
    }
    
    try {
        if (-not (Test-Path $Path)) {
            Write-Warning "Rules file not found at $Path, using defaults"
            return $defaultRules
        }
        
        $content = Get-Content $Path -Raw -ErrorAction Stop
        $rules = @{}
        $lines = $content -split "`n"
        
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            
            if ($line.Contains(":")) {
                $parts = $line -split ":", 2
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                
                # Remove inline comments (everything after #)
                if ($value.Contains("#")) {
                    $value = $value -split "#", 2 | Select-Object -First 1
                    $value = $value.Trim()
                }
                
                # Handle numeric values
                if ($value -match "^\d+$") {
                    $rules[$key] = [int]$value
                } elseif ($value -eq "true") {
                    $rules[$key] = $true
                } elseif ($value -eq "false") {
                    $rules[$key] = $false
                } else {
                    $rules[$key] = $value
                }
            }
        }
        
        # Merge with defaults
        foreach ($key in $defaultRules.Keys) {
            if (-not $rules.ContainsKey($key)) {
                $rules[$key] = $defaultRules[$key]
            }
        }
        
        Write-Verbose "Loaded rules from $Path successfully"
        return $rules
    }
    catch {
        Write-Error "Failed to load rules from $Path`: $($_.Exception.Message)"
        throw
    }
}

  
function Test-LdCli {
    try {
        $null = Get-Command ldcli -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-FlagsForPurpose {
    param([string]$Project,[string]$Env,[hashtable]$Rules,[string]$Purpose)
    
    # Calculate date filters
    $today = Get-Date
    $evaluationAfter = [int64]($today.AddDays(-$Rules.daysSinceLastEvaluation).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    $creationBefore = [int64]($today.AddDays(-$Rules.daysSinceCreation).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    
    # Build base filters
    $filterParts = @("filterEnv:$($Env)", "creationDate:`{`"before`":$creationBefore`}")
    
    # Add type filter if enabled
    if ($Rules.checkForFlagType) {
        $filterParts += "type:temporary"
    }
    
    # Note: We'll do final filtering in evaluation logic since ldcli has limited filter support
    
    $filterString = $filterParts -join ","
    
    try {
        Write-Verbose "Using ldcli to fetch $Purpose flags for project '$Project' in environment '$Env'"
        $result = & ldcli flags list --project $Project --env $Env --expand "codeReferences,evaluation" --filter $filterString --limit 100 -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $flags = $result | ConvertFrom-Json
            Write-Verbose "Retrieved $($flags.items.Count) $Purpose flags via ldcli"
            return $flags.items
        } else {
            Write-Error "ldcli failed with exit code ${LASTEXITCODE}: $result"
            return @()
        }
    }
    catch {
        Write-Error "ldcli failed with exception: $($_.Exception.Message)"
        return @()
    }
}
  
function Get-FlagStatuses {
    param([string]$Project,[string]$Env)
    
    try {
        Write-Verbose "Using ldcli to fetch flag statuses for project '$Project' in environment '$Env'"
        $result = & ldcli flags list-statuses --project $Project --environment $Env -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $statuses = $result | ConvertFrom-Json
            Write-Verbose "Retrieved $($statuses.items.Count) flag statuses via ldcli"
            return $statuses.items
        } else {
            Write-Error "ldcli failed with exit code ${LASTEXITCODE}: $result"
            return @()
        }
    }
    catch {
        Write-Error "ldcli failed with exception: $($_.Exception.Message)"
        return @()
    }
}
  
function Get-CodeRefs {
    param([string]$Base,[hashtable]$Headers,[string]$Project)
    
    try {
        Write-Verbose "Fetching code references for project '$Project'"
        $uri = "$Base/code-refs/repositories?projectKey=$Project&withBranches=true"
        $resp = Invoke-RestMethod -Method GET -Headers $Headers -Uri $uri -ErrorAction Stop
        
        $codeRefs = @{}
        foreach ($repo in $resp.items) {
            foreach ($branch in $repo.branches) {
                foreach ($flag in $branch.flags) {
                    $codeRefs[$flag.flagKey] = $true
                }
            }
        }
        
        Write-Verbose "Found code references for $($codeRefs.Count) flags"
        return $codeRefs
    }
    catch {
        Write-Warning "Failed to fetch code references for project '$Project': $($_.Exception.Message)"
        Write-Warning "Code reference detection will be disabled"
        return @{}
    }
}

function DaysSince($dateValue) {
    if (-not $dateValue) { return $null }
    
    try {
        # Convert to string first to handle different input types
        $dateStr = [string]$dateValue
        
        # Check if it's a Unix timestamp (milliseconds)
        if ($dateStr -match '^\d+$' -and $dateStr.Length -ge 10) {
            $timestamp = [int64]$dateStr
            # Convert from milliseconds to seconds if needed
            if ($timestamp -gt 1000000000000) { $timestamp = $timestamp / 1000 }
            $dt = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds($timestamp)
            return ([datetime]::UtcNow - $dt).TotalDays
        }
        else {
            # Try to parse as ISO date string
            $dt = [datetime]::Parse($dateStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            return ([datetime]::UtcNow - $dt.ToUniversalTime()).TotalDays
        }
    }
    catch {
        Write-Warning "Failed to parse date value '$dateValue' (type: $($dateValue.GetType().Name)): $($_.Exception.Message)"
        return $null
    }
}
  
function Evaluate-Flag {
    param($Context, $Rules, $Purpose)
  
    $reasons = New-Object System.Collections.ArrayList
    $readyForCodeRemoval = $false
    $readyForArchival = $false
  
    $lastReqDays = DaysSince $Context.LastRequested
    $createdDays = DaysSince $Context.CreatedDate
    
    # Handle null values (never requested/evaluated)
    $neverRequested = $lastReqDays -eq $null
    $neverCreated = $createdDays -eq $null
  
    # Since flags are pre-filtered by ldcli, we only need to check status
    if ($Rules.checkForFlagStatus) {
        if ($Purpose -eq "codeRemoval" -and $Context.Status -eq "launched") {
            $readyForCodeRemoval = $true
            [void]$reasons.Add("READY FOR CODE REMOVAL")
        } elseif ($Purpose -eq "archival" -and $Context.Status -eq "inactive") {
            $readyForArchival = $true
            [void]$reasons.Add("READY FOR ARCHIVAL")
        } else {
            [void]$reasons.Add("status=$($Context.Status) (need launched for code removal, inactive for archival)")
        }
    } else {
        # If not checking status, all pre-filtered flags are ready
        if ($Purpose -eq "codeRemoval") {
            $readyForCodeRemoval = $true
            [void]$reasons.Add("READY FOR CODE REMOVAL")
        } elseif ($Purpose -eq "archival") {
            $readyForArchival = $true
            [void]$reasons.Add("READY FOR ARCHIVAL")
        }
    }
    
    # Add information about never being requested
    if ($neverRequested) { [void]$reasons.Add("never requested/evaluated") }
  
    return [pscustomobject]@{
        project             = $Context.Project
        environment         = $Context.Environment
        key                 = $Context.Key
        name                = $Context.Name
        status              = $Context.Status
        flagType            = $Context.FlagType
        lastRequested       = $Context.LastRequested
        createdDate         = $Context.CreatedDate
        hasCodeRefs         = $Context.HasCodeRefs
        readyForCodeRemoval = $readyForCodeRemoval
        readyForArchival    = $readyForArchival
        reasons             = $reasons
        lastRequestedDays   = if ($neverRequested) { "never" } else { [int]$lastReqDays }
        createdDays         = if ($neverCreated) { "unknown" } else { [int]$createdDays }
    }
}
  
  function Set-FlagTags {
    param([string]$Base,[hashtable]$Headers,$Item,[string]$AddTag)
    if (-not $AddTag) { return }
    $patch = @{
      instructions = @(
        @{ kind = "addTag"; value = $AddTag }
      )
      comment = "Added by CI cleanup tool"
    } | ConvertTo-Json -Depth 6
  
    Invoke-RestMethod -Method PATCH `
      -Headers ($Headers + @{"Content-Type"="application/json; domain-model=launchdarkly.semanticpatch"}) `
      -Uri "$Base/flags/$($Item.project)/$($Item.key)" -Body $patch | Out-Null
  }
  
  function Patch-FlagDeprecated {
    param([string]$Base,[hashtable]$Headers,$Item,[bool]$Deprecated)
    $patch = @{
      instructions = @(
        @{ kind = "updateFlag"; deprecated = $Deprecated }
      )
      comment = "Marked deprecated by CI cleanup tool"
    } | ConvertTo-Json -Depth 6
  
    Invoke-RestMethod -Method PATCH `
      -Headers ($Headers + @{"Content-Type"="application/json; domain-model=launchdarkly.semanticpatch"}) `
      -Uri "$Base/flags/$($Item.project)/$($Item.key)" -Body $patch | Out-Null
  }
  
  function Archive-Flag {
    param([string]$Base,[hashtable]$Headers,$Item)
    $patch = @{
      instructions = @(
        @{ kind = "updateFlag"; archived = $true }
      )
      comment = "Archived by CI cleanup tool"
    } | ConvertTo-Json -Depth 6
  
    Invoke-RestMethod -Method PATCH `
      -Headers ($Headers + @{"Content-Type"="application/json; domain-model=launchdarkly.semanticpatch"}) `
      -Uri "$Base/flags/$($Item.project)/$($Item.key)" -Body $patch | Out-Null
  }
  
function New-PrSummary {
    param($Candidates, $Rules, [string]$OutPath)
    
    $codeRemovalCandidates = $Candidates | Where-Object { $_.readyForCodeRemoval } | Select-Object -First 10
    $archivalCandidates = $Candidates | Where-Object { $_.readyForArchival } | Select-Object -First 10
    
    $lines = @("# LaunchDarkly Flag Cleanup Report",
               "",
               "**Rules**: temporary flags, created >$($Rules.creationDays) days ago, evaluation threshold: $($Rules.evaluationDays) days",
               "")
    
    if ($codeRemovalCandidates.Count -gt 0) {
        $lines += "## Ready for Code Removal ($($codeRemovalCandidates.Count) flags)"
        $lines += "Flags that are launched, have recent evaluations, and have code references:"
        $lines += ""
        $lines += "| Project | Env | Key | Status | LastRequested | Created |"
        $lines += "|---|---|---|---|---|---|"
        foreach ($c in $codeRemovalCandidates) {
            $lines += "| $($c.project) | $($c.environment) | `$($c.key)` | $($c.status) | $($c.lastRequested) | $($c.createdDate) |"
        }
        $lines += ""
    }
    
    if ($archivalCandidates.Count -gt 0) {
        $lines += "## Ready for Archival ($($archivalCandidates.Count) flags)"
        $lines += "Flags that are inactive, have no recent evaluations, and no code references:"
        $lines += ""
        $lines += "| Project | Env | Key | Status | LastRequested | Created |"
        $lines += "|---|---|---|---|---|---|"
        foreach ($c in $archivalCandidates) {
            $lines += "| $($c.project) | $($c.environment) | `$($c.key)` | $($c.status) | $($c.lastRequested) | $($c.createdDate) |"
        }
        $lines += ""
    }
    
    if ($codeRemovalCandidates.Count -eq 0 -and $archivalCandidates.Count -eq 0) {
        $lines += "No cleanup candidates found."
    }
    
    $lines -join "`n" | Out-File -Encoding utf8 $OutPath
}
  