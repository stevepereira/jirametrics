<#
.SYNOPSIS
    Downloads Jira data for JiraMetrics offline mode.
.DESCRIPTION
    This script replicates the download logic of JiraMetrics, fetching issues,
    changelogs, statuses, board configurations, and sprints from Jira Server (API v2)
    using a Personal Access Token (PAT).
.EXAMPLE
    .\Get-JiraData.ps1 -JiraUrl "https://jira.example.com" -Token "YOUR_PAT" -BoardId 123 -ProjectPrefix "MYPROJ" -TargetPath "./data"
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$JiraUrl,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [int]$BoardId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectPrefix,

    [string]$TargetPath = ".",

    [int]$RollingDays = 90
)

$ErrorActionPreference = "Stop"

# Ensure JiraUrl doesn't end with slash
$JiraUrl = $JiraUrl.TrimEnd('/')

$Headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

if (-not (Test-Path $TargetPath)) {
    New-Item -ItemType Directory -Path $TargetPath | Out-Null
}

$IssuesPath = Join-Path $TargetPath "$($ProjectPrefix)_issues"
if (-not (Test-Path $IssuesPath)) {
    New-Item -ItemType Directory -Path $IssuesPath | Out-Null
}

function Invoke-JiraRequest {
    param($RelativeUrl)
    $Url = "$JiraUrl$RelativeUrl"
    Write-Host "Fetching: $Url"
    return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
}

# 1. Download Statuses
Write-Host "Downloading all statuses..."
$Statuses = Invoke-JiraRequest "/rest/api/2/status"
$Statuses | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TargetPath "$($ProjectPrefix)_statuses.json") -Encoding utf8

# 2. Download Board Configuration
Write-Host "Downloading board configuration for board $BoardId..."
$BoardConfig = Invoke-JiraRequest "/rest/agile/1.0/board/$BoardId/configuration"
$BoardConfig | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TargetPath "$($ProjectPrefix)_board_$($BoardId)_configuration.json") -Encoding utf8

$FilterId = $BoardConfig.filter.id

# 3. Download Sprints (if Scrum)
if ($BoardConfig.type -eq "scrum") {
    Write-Host "Downloading sprints for board $BoardId..."
    $StartAt = 0
    $IsLast = $false
    while (-not $IsLast) {
        $SprintsJson = Invoke-JiraRequest "/rest/agile/1.0/board/$BoardId/sprint?startAt=$StartAt"
        $SprintsJson | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TargetPath "$($ProjectPrefix)_board_$($BoardId)_sprints_$($StartAt).json") -Encoding utf8

        $IsLast = $SprintsJson.isLast
        if ($SprintsJson.values) {
            $StartAt += $SprintsJson.values.Count
        } else {
            $IsLast = $true
        }
    }
}

# 4. Download Issues
$Today = Get-Date
$StartDate = $Today.AddDays(-$RollingDays).ToString("yyyy-MM-dd")
$Jql = "filter=$FilterId AND updated >= '$StartDate 00:00'"
Write-Host "Downloading issues with JQL: $Jql"

$StartAt = 0
$Total = 1
$DownloadedKeys = @{}

while ($StartAt -lt $Total) {
    $EscapedJql = [uri]::EscapeDataString($Jql)
    $SearchUrl = "/rest/api/2/search?jql=$EscapedJql&maxResults=50&startAt=$StartAt&expand=changelog&fields=*all"
    $Results = Invoke-JiraRequest $SearchUrl

    $Total = $Results.total
    foreach ($Issue in $Results.issues) {
        $Issue | Add-Member -MemberType NoteProperty -Name "exporter" -Value @{ "in_initial_query" = $true }
        $IssueKey = $Issue.key
        $DownloadedKeys[$IssueKey] = $true
        $Filename = "$IssueKey-$BoardId.json"
        $Issue | ConvertTo-Json -Depth 10 | Out-File (Join-Path $IssuesPath $Filename) -Encoding utf8
    }

    $StartAt += $Results.issues.Count
    Write-Host "Downloaded $($StartAt) of $Total issues..."
}

# 5. Download Linked Issues & Parents (Optional but recommended for full parity)
# For simplicity in this script, we'll only do one level of linked issues if they were missing.
# JiraMetrics handles missing linked issues by just not showing them or showing them as "fragments".
# A full recursive downloader is complex in PowerShell, but let's at least try to get parents.

Write-Host "Checking for parents and subtasks..."
$PendingKeys = @()
foreach ($File in Get-ChildItem $IssuesPath -Filter "*.json") {
    $Issue = Get-Content $File.FullName | ConvertFrom-Json

    # Check Parent
    if ($Issue.fields.parent -and -not $DownloadedKeys.ContainsKey($Issue.fields.parent.key)) {
        $PendingKeys += $Issue.fields.parent.key
    }
    # Check Subtasks
    if ($Issue.fields.subtasks) {
        foreach ($Subtask in $Issue.fields.subtasks) {
            if (-not $DownloadedKeys.ContainsKey($Subtask.key)) {
                $PendingKeys += $Subtask.key
            }
        }
    }
}

$PendingKeys = $PendingKeys | Select-Object -Unique
if ($PendingKeys.Count -gt 0) {
    Write-Host "Downloading $($PendingKeys.Count) related issues..."
    # Batch download related issues
    for ($i = 0; $i -lt $PendingKeys.Count; $i += 50) {
        $Batch = $PendingKeys[$i..($i + 49)] -join ","
        $BatchJql = "key in ($Batch)"
        $EscapedBatchJql = [uri]::EscapeDataString($BatchJql)
        $Results = Invoke-JiraRequest "/rest/api/2/search?jql=$EscapedBatchJql&expand=changelog&fields=*all"

        foreach ($Issue in $Results.issues) {
            $Issue | Add-Member -MemberType NoteProperty -Name "exporter" -Value @{ "in_initial_query" = $false }
            $IssueKey = $Issue.key
            $Filename = "$IssueKey-$BoardId.json"
            $Issue | ConvertTo-Json -Depth 10 | Out-File (Join-Path $IssuesPath $Filename) -Encoding utf8
        }
    }
}

# 6. Download Users
Write-Host "Downloading users..."
# Note: /rest/api/2/users is often restricted or behaves differently on Server vs Cloud.
# On Server, you might need /rest/api/2/user/search?username=.
# But JiraMetrics mainly uses this for Atlassian Document Format rendering.
try {
    $Users = Invoke-JiraRequest "/rest/api/2/users"
    $Users | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TargetPath "$($ProjectPrefix)_users.json") -Encoding utf8
} catch {
    Write-Warning "Could not download users list. This is normal if you don't have admin permissions."
}

# 7. Create Metadata
Write-Host "Creating metadata file..."
$Metadata = @{
    "version" = 5
    "date_start" = $StartDate
    "date_end" = $Today.ToString("yyyy-MM-dd")
    "jira_url" = $JiraUrl
}
$Metadata | ConvertTo-Json | Out-File (Join-Path $TargetPath "$($ProjectPrefix)_meta.json") -Encoding utf8

Write-Host "Done! Data is ready in $TargetPath"
