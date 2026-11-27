<#
.SYNOPSIS
  git_flow.ps1 v2.2.0 - AUTOSAR & GitLab workflow assistant for main + nested component repos.

.DESCRIPTION
  Run from your Main Repo root (or inside any component) with no arguments for the
  interactive workspace dashboard & menu, OR script it via flags.
  Automatically handles:
    - Seeing all changes & unpushed commits across Main Repo and all nested component repos
    - Running 'git fetch --all' (including in .repo if present)
    - Finding 'develop' on the remote (even when 'git branch' does not list it locally),
      checking out local 'develop', and pulling latest changes before branching
    - Enforcing <JIRA-ID>-<title> or <feature|bugfix|hotfix>/<JIRA-ID>-<title> branch names
    - Enforcing "<JIRA-ID>: <description>" commit messages (and offering to fix manual commits)
    - Interactive selective file staging (pick individual files if you don't want git add -A)
    - Pushing with 'git push --set-upstream' and creating/opening GitLab Merge Requests

  ACTIONS
    --wizard              One-command full workflow: Branch + Commit + Push + MR
    --health              Compact workspace health summary (changed, ahead, detached, on develop)
    --status              Show branch, modified files & unpushed commits across all workspace repos
    --sync                Run fetch --all + checkout develop + pull across all workspace repos
    --branch              Fetch, update develop, and create branch for Jira task (supports -c can,dcm)
                          (implied when --jira / --type / --desc are given alone)
    -m, --commit "<msg>"  Commit; "<JIRA-ID>: " prefix is added automatically
    -p, --push            Push current branch (--set-upstream) + print MR hand-off text
        --mr              Push and auto-create the MR/PR (removes source branch on merge in GitLab)
        --mr-text         Only print/copy the MR title + description
        --undo-commit     Safely undo the last UNPUSHED commit (keeps all file changes intact)
        --update          Update current work branch with latest origin/develop (conflict-checked)
        --discard         Safely discard unwanted file changes (saves a git stash backup first)

  INPUTS
    -c, --component <name|path>   Component repo folder (or pick interactively from Main Repo)
    -j, --jira <ID>               Jira task ID, e.g. OSKDC33837-14809
        --jira-from-branch        Auto-extract Jira ID from current branch name (or changed files)
    -t, --type <type>             none | feature | bugfix | hotfix (default: none -> PROJ-123-title)
    -d, --desc "<text>"           Branch title / short description (required)
    -b, --base <branch>           Base/target branch               (default: develop)
    -r, --remote <name>           Remote name                      (default: origin)
    -a, --assignee <cdsid>        GitLab Assignee CDS ID (e.g. jfernan1)
        --reviewer <cdsid(s)>     GitLab Reviewer CDS ID(s) (e.g. rkumar2 or "rkumar2,asmith3")

  BEHAVIOUR
    -n, --dry-run     Show every mutating command without running it
    -y, --yes         Non-interactive: never prompt, use safe defaults
        --carry       Carry uncommitted changes onto the new branch (without stashing)
        --stash       Auto-stash tracked changes before creating a branch
        --all         Stage everything when nothing is staged (git add -A)
        --model-only  Stage only Rhapsody model files (*.rpwx, *.sbsx, *.rpy), skipping .bak/.tmp/generated
        --draft       Create the MR/PR as draft
        --no-fetch    Skip 'git fetch' (offline work; push still needs network)
        --force       Bypass branch-name / Jira-mismatch / sensitive-file checks
                      (never bypasses protected-branch blocking)
        --no-color    Disable colours
    -h, --help        This help        --version   Print version

  EXAMPLES
    .\git_flow.bat                                         # workspace dashboard + guided menu
    .\git_flow.bat --status                                # see all changes across all components
    .\git_flow.bat --sync                                  # fetch --all + checkout develop + pull all
    .\git_flow.bat -c dcm --branch -j PROJ-123 -d "fix can parser"
    .\git_flow.bat -c dcm --commit "handle empty frame" --all --push --mr
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:VERSION = '3.0.0'
$EX_USAGE = 2; $EX_NOTFOUND = 3; $EX_STATE = 4; $EX_NETWORK = 5
$EX_PROTECTED = 6; $EX_GIT = 7; $EX_MR = 8; $EX_ABORT = 130

# ------------------------------------------------------------ configuration ---
$script:BaseBranch = if ($env:GIT_FLOW_BASE) { $env:GIT_FLOW_BASE } else { 'develop' }
$script:DefaultRemote = if ($env:GIT_FLOW_REMOTE) { $env:GIT_FLOW_REMOTE } else { 'origin' }
$script:Remote = $script:DefaultRemote
$script:RemoteExplicit = [bool]$env:GIT_FLOW_REMOTE
$script:JiraPattern = if ($env:GIT_FLOW_JIRA_PATTERN) { $env:GIT_FLOW_JIRA_PATTERN } else { '[A-Z][A-Z0-9_]*-[0-9]+' }
$script:JiraUrl = if ($env:GIT_FLOW_JIRA_URL) { $env:GIT_FLOW_JIRA_URL } else { '' }
$script:ExtraProtected = if ($env:GIT_FLOW_PROTECTED) { @($env:GIT_FLOW_PROTECTED -split '\s+' | Where-Object { $_ }) } else { @() }
$script:MaxDepth = if ($env:GIT_FLOW_MAX_DEPTH) { [int]$env:GIT_FLOW_MAX_DEPTH } else { 10 }
$script:ExcludeDirs = @('node_modules', 'build', 'out', 'dist', 'target', '.venv', 'venv', '__pycache__', '.cache', '.gradle', '.idea', '.vscode', '.tox', '.mypy_cache', '.next')
if ($env:GIT_FLOW_EXCLUDES) { $script:ExcludeDirs += @($env:GIT_FLOW_EXCLUDES -split '\s+' | Where-Object { $_ }) }
$script:JiraRegex = '^' + $script:JiraPattern + '$'
$script:BranchRegex = '^((feature|bugfix|hotfix)/)?' + $script:JiraPattern + '-.+$'

# ------------------------------------------------------------------- state ----
$script:DryRun = $false; $script:Yes = $false; $script:NonInteractive = $false; $script:UseColor = $true
$script:NoFetch = $false; $script:Force = $false; $script:StageAll = $false; $script:ModelOnly = $false; $script:AutoStash = $false; $script:CarryChanges = $false; $script:CarryFlag = $false; $script:JiraFromBranch = $false; $script:Draft = $false
$script:DoBranch = $false; $script:DoCommit = $false; $script:DoPush = $false; $script:DoMr = $false; $script:DoMrText = $false
$script:DoSync = $false; $script:DoStatus = $false; $script:DoHealth = $false; $script:DoWizard = $false; $script:DoUndo = $false; $script:DoUpdate = $false; $script:DoDiscard = $false
$script:Component = ''; $script:JiraId = ''; $script:LastJiraId = ''; $script:BranchType = ''; $script:Desc = ''; $script:CommitMsg = ''
$script:Assignee = if ($env:GIT_FLOW_ASSIGNEE) { $env:GIT_FLOW_ASSIGNEE } else { '' }
$script:Reviewer = if ($env:GIT_FLOW_REVIEWER) { $env:GIT_FLOW_REVIEWER } else { '' }
$script:LastAssignee = $script:Assignee; $script:LastReviewer = $script:Reviewer; $script:MrPeoplePrompted = $false
$script:WorkspaceRoot = (Get-Location).ProviderPath
$script:RepoDir = ''; $script:MultiRepos = @(); $script:CurBranch = ''; $script:Detached = $false
$script:BranchName = ''; $script:Sanitized = ''
$script:StashCreated = $false; $script:StashMsg = ''; $script:SimCommit = $false; $script:MrFailed = $false
$script:HasStaged = $false; $script:FormattedMsg = ''; $script:PushUrl = ''; $script:MrTitle = ''; $script:MrBody = ''; $script:MrTool = ''
$script:MrCreatedViaPush = $false; $script:MrMode = ''
$script:GitExit = 0; $script:LastLog = ''; $script:MenuMode = $false; $script:MrBodyFile = ''
$script:Self = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { './git_flow.ps1' }
$script:TempFiles = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- output ------
function Write-Line([string]$Text, [string]$Color) {
    if ($script:UseColor -and $Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Info([string]$m) { Write-Line "[..] $m" 'Cyan' }
function Ok([string]$m) { Write-Line "[OK] $m" 'Green' }
function Warn([string]$m) { Write-Line "[!!] $m" 'Yellow' }
function Hint([string]$m) { Write-Line "     -> $m" 'DarkGray' }
function Step([string]$m) { Write-Host ''; Write-Line "==> $m" 'White' }

function Die([int]$Code, [string]$Message, [string[]]$Hints = @()) {
    $ex = New-Object System.Exception $Message
    $ex.Data['Code'] = $Code
    $ex.Data['Hints'] = $Hints
    throw $ex
}

# ------------------------------------------------------------- utilities -----
function Format-Arg([string]$a) {
    if ($a -match '^[\w@%+=:,./\\-]+$') { return $a }
    return "'" + ($a -replace "'", "''") + "'"
}
function Format-Cmd([string[]]$CmdArgs) { return (($CmdArgs | ForEach-Object { Format-Arg $_ }) -join ' ') }
function Dry-Echo([string[]]$CmdArgs) {
    Write-Line ("  [dry-run] would run: git " + (Format-Cmd $CmdArgs)) 'Yellow'
}
function Convert-NativeArg([string]$a) {
    $legacy = ($PSVersionTable.PSVersion.Major -lt 7)
    if (-not $legacy -and (Get-Variable -Name PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue)) {
        $legacy = ($PSNativeCommandArgumentPassing -eq 'Legacy')
    }
    if ($legacy) { return ($a -replace '"', '\"') }
    return $a
}

# --- native git wrappers (never throw on non-zero; always set $script:GitExit) ---
function Git-Out {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git @args 2>$null } finally { $ErrorActionPreference = $prev }
    $script:GitExit = $LASTEXITCODE
    if ($null -eq $o) { return '' }
    return (($o | ForEach-Object { "$_" }) -join "`n").TrimEnd()
}
function Git-Cap {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git @args 2>&1 } finally { $ErrorActionPreference = $prev }
    $script:GitExit = $LASTEXITCODE
    if ($null -eq $o) { return '' }
    $lines = $o | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { if ($null -ne $_.TargetObject) { [string]$_.TargetObject } else { '' } }
        else { "$_" }
    }
    return ($lines -join "`n").TrimEnd()
}
function Git-Ok { [void](Git-Out @args); return ($script:GitExit -eq 0) }
function Git-Show { $t = Git-Cap @args; if ($t) { Write-Host $t } }

function Try-Git([string[]]$GitArgs) {
    $script:LastLog = ''
    if ($script:DryRun) { Dry-Echo $GitArgs; return 0 }
    $t = Git-Cap @GitArgs
    $script:LastLog = $t
    if ($t) { Write-Host $t }
    return $script:GitExit
}
function Run-Git([string[]]$GitArgs) {
    $rc = Try-Git $GitArgs
    if ($rc -ne 0) {
        Die $EX_GIT ("Command failed (exit $rc): git " + (Format-Cmd $GitArgs)) @('Read the git output above, fix the cause, then re-run (add --dry-run to preview).')
    }
}

function Confirm-Action([string]$Question, [string]$Default, [bool]$Auto) {
    if ($script:NonInteractive) { return $Auto }
    $pr = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Question $pr"
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $Default }
    return ($a -match '^[Yy]')
}
function Read-Value([string]$Text, [string]$Default = '') {
    if ($script:NonInteractive) { return $null }
    if ($Default) {
        $a = Read-Host "$Text [$Default]"
        if ([string]::IsNullOrWhiteSpace($a)) { $a = $Default }
    } else {
        $a = Read-Host $Text
    }
    if ($null -eq $a) { return '' }
    return $a.Trim()
}
function Pick-FromList([string]$Prompt, [string[]]$Items) {
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $Items[$i]) }
    while ($true) {
        $sel = Read-Host "$Prompt (1-$($Items.Count), q to quit)"
        if ($sel -match '^[qQ]') { Die $EX_ABORT 'Cancelled.' }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Warn "Please enter a number between 1 and $($Items.Count)."
    }
}

# ------------------------------------------------------------- arg parsing ----
function Show-Usage {
    $text = Get-Content -LiteralPath $script:Self -Raw -ErrorAction SilentlyContinue
    if ($text -and $text -match '(?s)<#(.*?)#>') {
        Write-Host ($Matches[1].Trim("`r", "`n"))
    } else {
        Write-Host 'See the header comment of git_flow.ps1 for usage.'
    }
}

function Parse-Args([object[]]$Argv) {
    $needsValue = @('c', 'component', 'j', 'jira', 't', 'type', 'd', 'desc', 'description', 'b', 'base', 'r', 'remote', 'a', 'assignee', 'reviewer')
    $i = 0
    while ($i -lt $Argv.Count) {
        $tok = [string]$Argv[$i]
        $inline = $null
        if ($tok -match '^(--?[A-Za-z][A-Za-z0-9-]*)[=:](.*)$') { $tok = $Matches[1]; $inline = $Matches[2] }
        if ($tok -notmatch '^--?[A-Za-z]') { Die $EX_USAGE "Unexpected argument: $tok" @("See: $($script:Self) --help") }
        $key = $tok.TrimStart('-').Replace('-', '').ToLowerInvariant()
        $val = $null
        if ($needsValue -contains $key) {
            if ($null -ne $inline) { $val = $inline }
            else {
                if (($i + 1) -ge $Argv.Count -or ([string]$Argv[$i + 1]).StartsWith('-')) {
                    Die $EX_USAGE "Option $tok requires a value." @('See --help')
                }
                $i++; $val = [string]$Argv[$i]
            }
        }
        switch ($key) {
            { $_ -in @('h', 'help') } { Show-Usage; exit 0 }
            'version' { Write-Host $script:VERSION; exit 0 }
            { $_ -in @('n', 'dryrun') } { $script:DryRun = $true }
            { $_ -in @('y', 'yes') } { $script:Yes = $true }
            { $_ -in @('c', 'component') } { $script:Component = $val }
            { $_ -in @('j', 'jira') } { $script:JiraId = $val }
            { $_ -in @('t', 'type') } { $script:BranchType = $val.ToLowerInvariant() }
            { $_ -in @('d', 'desc', 'description') } { $script:Desc = $val }
            { $_ -in @('b', 'base') } { $script:BaseBranch = $val }
            { $_ -in @('r', 'remote') } { $script:Remote = $val; $script:DefaultRemote = $val; $script:RemoteExplicit = $true }
            { $_ -in @('a', 'assignee') } { $script:Assignee = $val; $script:LastAssignee = $val }
            'reviewer' { $script:Reviewer = $val; $script:LastReviewer = $val }
            { $_ -in @('m', 'commit') } {
                $script:DoCommit = $true
                if ($null -ne $inline) { $script:CommitMsg = $inline }
                elseif (($i + 1) -lt $Argv.Count -and -not ([string]$Argv[$i + 1]).StartsWith('-')) { $i++; $script:CommitMsg = [string]$Argv[$i] }
            }
            { $_ -in @('p', 'push') } { $script:DoPush = $true }
            'branch' { $script:DoBranch = $true }
            'mr' { $script:DoMr = $true }
            'mrtext' { $script:DoMrText = $true }
            'sync' { $script:DoSync = $true }
            'status' { $script:DoStatus = $true }
            'health' { $script:DoHealth = $true }
            'wizard' { $script:DoWizard = $true }
            { $_ -in @('undo', 'undocommit') } { $script:DoUndo = $true }
            'update' { $script:DoUpdate = $true }
            'discard' { $script:DoDiscard = $true }
            'draft' { $script:Draft = $true }
            'all' { $script:StageAll = $true }
            'modelonly' { $script:ModelOnly = $true }
            'carry' { $script:CarryFlag = $true }
            'jirafrombranch' { $script:JiraFromBranch = $true }
            'stash' { $script:AutoStash = $true }
            'nofetch' { $script:NoFetch = $true }
            'force' { $script:Force = $true }
            'nocolor' { $script:UseColor = $false }
            default { Die $EX_USAGE "Unknown option: $tok" @("See: $($script:Self) --help") }
        }
        $i++
    }
    if ($script:BranchType -in @('direct', 'jira')) { $script:BranchType = 'none' }
    if ($script:BranchType -and @('none', 'feature', 'bugfix', 'hotfix') -notcontains $script:BranchType) {
        Die $EX_USAGE "Invalid --type '$($script:BranchType)'." @('Allowed: none (direct Jira ID), feature, bugfix, hotfix')
    }
    if ($script:Yes -or [Console]::IsInputRedirected) { $script:NonInteractive = $true }
    if ($env:NO_COLOR) { $script:UseColor = $false }
}

function Determine-Mode {
    if ($script:DoMr -and -not $script:DoWizard) { $script:DoPush = $true }
    if (-not ($script:DoBranch -or $script:DoCommit -or $script:DoPush -or $script:DoMrText -or $script:DoSync -or $script:DoStatus -or $script:DoHealth -or $script:DoWizard -or $script:DoUndo -or $script:DoUpdate -or $script:DoDiscard)) {
        if ($script:JiraId -or $script:Desc -or $script:BranchType -or $script:JiraFromBranch) { $script:DoBranch = $true }
        elseif ($script:NonInteractive) {
            Die $EX_USAGE 'No action given and no terminal available for the menu.' @('Use one of: --wizard | --health | --status | --sync | --branch | --commit "msg" | --push | --mr-text | --undo-commit | --update | --discard', "See: $($script:Self) --help")
        }
        else { $script:MenuMode = $true }
    }
    if ($script:DoBranch -and ($script:DoCommit -or $script:DoPush -or $script:DoMrText -or $script:DoSync -or $script:DoStatus -or $script:DoHealth -or $script:DoWizard -or $script:DoUndo -or $script:DoUpdate -or $script:DoDiscard)) {
        Die $EX_USAGE '--branch cannot be combined with other action flags (use --wizard for branch + commit + push in one go).'
    }
    if ($script:DoMrText -and ($script:DoCommit -or $script:DoPush)) {
        Die $EX_USAGE '--mr-text cannot be combined with --commit/--push/--mr.'
    }
}

# -------------------------------------------------- component discovery ------
function Find-Repos([string]$Root) {
    $result = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $dir = [string]$item[0]; $depth = [int]$item[1]
        if (-not $visited.Add($dir)) { continue }
        $g = [System.IO.Path]::Combine($dir, '.git')
        if (Test-Path -LiteralPath $g) { $result.Add($dir) }
        if ($depth -ge $script:MaxDepth) { continue }
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($s in $subs) {
            $n = [System.IO.Path]::GetFileName($s)
            if ($n -eq '.git' -or $n -eq '.repo' -or ($script:ExcludeDirs -contains $n)) { continue }
            $stack.Push(@($s, $depth + 1))
        }
    }
    return @($result | Sort-Object)
}

function Get-RepoRelativeLabel([string]$Root, [string]$Dir) {
    $rn = $Root.Replace('\', '/').TrimEnd('/')
    $dn = $Dir.Replace('\', '/').TrimEnd('/')
    if ($dn -eq $rn) { return (Split-Path $Root -Leaf) + ' (Main Repo)' }
    if ($dn.StartsWith($rn + '/')) { return $dn.Substring($rn.Length + 1) }
    return $dn
}

function Get-RepoQuickStatus([string]$Dir) {
    $br = Git-Out -C $Dir symbolic-ref --short -q HEAD
    $detached = ($script:GitExit -ne 0 -or -not $br)
    if ($detached) {
        $sha = Git-Out -C $Dir rev-parse --short HEAD
        $brLabel = if ($sha) { "DETACHED@$sha (manifest-managed)" } else { 'UNINITIALIZED' }
    } else {
        $brLabel = $br
    }
    $porcelain = Git-Out -C $Dir status --porcelain
    $lines = @($porcelain -split "`n" | Where-Object { $_.Trim() })

    # Check if there are unpushed local commits on an active work branch
    $unpushed = 0
    if (-not $detached -and -not (Test-Protected $br)) {
        $cnt = Git-Out -C $Dir rev-list --count "@{u}..HEAD" --
        if ($script:GitExit -eq 0 -and $cnt) {
            $unpushed = [int]$cnt
        } else {
            $cnt2 = Git-Out -C $Dir rev-list --count "$($script:DefaultRemote)/$($script:BaseBranch)..HEAD" --
            if ($script:GitExit -eq 0 -and $cnt2) { $unpushed = [int]$cnt2 }
        }
    }

    return [PSCustomObject]@{
        Path          = $Dir
        Branch        = $brLabel
        Detached      = $detached
        ChangedCount  = $lines.Count
        ChangedLines  = $lines
        UnpushedCount = $unpushed
    }
}

function Show-WorkspaceDashboard([string]$Root, [string[]]$Repos) {
    Step "Workspace Overview ($($Repos.Count) repositories under $Root)"
    $statuses = @()
    foreach ($r in $Repos) {
        $st = Get-RepoQuickStatus $r
        $label = Get-RepoRelativeLabel $Root $r
        $st | Add-Member -NotePropertyName Label -NotePropertyValue $label
        $statuses += $st
    }
    for ($i = 0; $i -lt $statuses.Count; $i++) {
        $st = $statuses[$i]
        $idx = ("[{0}]" -f ($i + 1)).PadLeft(5)
        $lbl = $st.Label.PadRight(28)
        $br = ("[" + $st.Branch + "]").PadRight(36)
        $unpushedInfo = if ($st.UnpushedCount -gt 0) { ", $($st.UnpushedCount) unpushed commit(s)" } else { '' }
        if ($st.ChangedCount -gt 0) {
            Write-Line ("  $idx * $lbl $br -> $($st.ChangedCount) changed file(s)$unpushedInfo") 'Yellow'
            $preview = @($st.ChangedLines | Select-Object -First 6)
            foreach ($p in $preview) { Write-Line ("            $p") 'DarkYellow' }
            if ($st.ChangedCount -gt 6) { Write-Line ("            ... and $($st.ChangedCount - 6) more") 'DarkYellow' }
        } elseif ($st.UnpushedCount -gt 0) {
            Write-Line ("  $idx ^ $lbl $br -> clean ($($st.UnpushedCount) unpushed commit(s) ready to push)") 'Cyan'
        } else {
            $color = if ($st.Detached) { 'DarkGray' } else { 'Green' }
            Write-Line ("  $idx   $lbl $br -> clean") $color
        }
    }
    return $statuses
}

function Show-WorkspaceHealth([string]$Root, [string[]]$Repos) {
    Step 'Workspace Health'
    Write-Host "Repositories: $($Repos.Count)"
    $changed = New-Object System.Collections.Generic.List[string]
    $ahead   = New-Object System.Collections.Generic.List[string]
    $onBase  = New-Object System.Collections.Generic.List[string]
    $onWork  = New-Object System.Collections.Generic.List[string]
    $detachedCount = 0

    foreach ($r in $Repos) {
        $st = Get-RepoQuickStatus $r
        $lbl = Get-RepoRelativeLabel $Root $r
        if ($st.ChangedCount -gt 0) { $changed.Add("$lbl ($($st.ChangedCount) file(s))") }
        if ($st.UnpushedCount -gt 0) { $ahead.Add("$lbl ($($st.UnpushedCount) commit(s))") }
        if ($st.Detached) { $detachedCount++ }
        elseif ($st.Branch -eq $script:BaseBranch) { $onBase.Add($lbl) }
        else { $onWork.Add("$lbl [$($st.Branch)]") }
    }

    Write-Host ''
    Write-Line 'Changed:' 'Yellow'
    if ($changed.Count -gt 0) { foreach ($c in $changed) { Write-Host "  $c" } } else { Write-Host '  none' }

    Write-Host ''
    Write-Line 'Ahead of remote:' 'Cyan'
    if ($ahead.Count -gt 0) { foreach ($a in $ahead) { Write-Host "  $a" } } else { Write-Host '  none' }

    Write-Host ''
    Write-Line 'Detached (manifest-managed):' 'DarkGray'
    Write-Host "  $detachedCount repos"

    Write-Host ''
    Write-Line "On $($script:BaseBranch):" 'Green'
    if ($onBase.Count -gt 0) { foreach ($b in $onBase) { Write-Host "  $b" } } else { Write-Host '  none' }

    if ($onWork.Count -gt 0) {
        Write-Host ''
        Write-Line 'On task / feature branches:' 'White'
        foreach ($w in $onWork) { Write-Host "  $w" }
    }
}

function Match-Repos([string]$Root, [string]$Name) {
    $Name = $Name.Replace('\', '/').TrimEnd('/')
    if ($Name.StartsWith('./')) { $Name = $Name.Substring(2) }
    $all = @(Find-Repos $Root)
    $rootN = $Root.Replace('\', '/').TrimEnd('/')
    foreach ($exact in @($true, $false)) {
        $found = @()
        foreach ($d in $all) {
            $dn = $d.Replace('\', '/')
            $rel = if ($dn.StartsWith($rootN + '/')) { $dn.Substring($rootN.Length + 1) } else { $dn }
            $base = $dn.Substring($dn.LastIndexOf('/') + 1)
            if ($exact) { $hit = ($base -ceq $Name) -or ($rel -ceq $Name) -or ($rel.EndsWith('/' + $Name, [System.StringComparison]::Ordinal)) }
            else { $hit = ($base -eq $Name) -or ($rel -eq $Name) -or ($rel.EndsWith('/' + $Name, [System.StringComparison]::OrdinalIgnoreCase)) }
            if ($hit) { $found += $d }
        }
        if ($found.Count -gt 0) { return $found }
    }
    return @()
}

function Resolve-Repo {
    $top = Git-Out rev-parse --show-toplevel
    if ($script:GitExit -ne 0) { $top = '' } elseif ($top) { $top = [System.IO.Path]::GetFullPath($top) }
    $pwdPath = (Get-Location).ProviderPath
    $script:WorkspaceRoot = if ($top) { $top } else { $pwdPath }

    if ($script:Component) {
        # Support comma-separated components for multi-component branching (e.g. -c can,dcm)
        if ($script:Component -match ',') {
            $parts = @($script:Component -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($parts.Count -gt 1) {
                $resolved = New-Object System.Collections.Generic.List[string]
                foreach ($p in $parts) {
                    $m = @(Match-Repos $pwdPath $p)
                    if ($m.Count -eq 1) { if (-not $resolved.Contains($m[0])) { $resolved.Add($m[0]) } }
                    elseif ($m.Count -gt 1) {
                        if ($script:NonInteractive) { Die $EX_NOTFOUND "Ambiguous component '$p'." }
                        Warn "Multiple repos match '$p':"
                        $picked = Pick-FromList 'Repository' $m
                        if (-not $resolved.Contains($picked)) { $resolved.Add($picked) }
                    } else {
                        Die $EX_NOTFOUND "No git repository named '$p' found under $pwdPath."
                    }
                }
                $script:MultiRepos = @($resolved.ToArray())
                $script:RepoDir = $script:MultiRepos[0]
                return
            }
        }
        $name = $script:Component.TrimEnd('\', '/')
        $asPath = $name
        if ((Test-Path -LiteralPath $asPath -PathType Container) -and (Test-Path -LiteralPath (Join-Path $asPath '.git'))) {
            $script:RepoDir = (Resolve-Path -LiteralPath $asPath).ProviderPath; return
        }
        $nameN = $name.Replace('\', '/')
        if ($top) {
            $topN = $top.Replace('\', '/')
            if ($topN.Substring($topN.LastIndexOf('/') + 1) -eq $nameN -or $topN.EndsWith('/' + $nameN)) { $script:RepoDir = $top; return }
        }
        $roots = @($pwdPath)
        if ($top -and $top -ne $pwdPath) { $roots += $top }
        if ($top) {
            $sup = Git-Out rev-parse --show-superproject-working-tree
            if ($script:GitExit -eq 0 -and $sup) { $roots += [System.IO.Path]::GetFullPath($sup) }
        }
        $matches2 = @()
        foreach ($root in $roots) {
            Info "Searching '$root' for git repo '$name'..."
            $matches2 = @(Match-Repos $root $name)
            if ($matches2.Count -gt 0) { break }
        }
        if ($matches2.Count -eq 0) {
            $plain = @()
            try {
                $plain = @(Get-ChildItem -LiteralPath $pwdPath -Directory -Recurse -Depth 4 -Filter $name -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -notmatch '[\\/](node_modules|build|out|\.venv|\.git)[\\/]' } | Select-Object -First 5 | ForEach-Object { $_.FullName })
            } catch { $plain = @() }
            $h = @('Check the spelling, or pass a path:  --component path/to/' + $name)
            if ($plain.Count -gt 0) { $h += ('Folders with that name exist but have no .git (not a repo/submodule): ' + ($plain -join ' ')) }
            $h += 'Submodule not checked out?  git submodule update --init --recursive'
            Die $EX_NOTFOUND ("No git repository named '$name' found under: " + ($roots -join ' ')) $h
        }
        if ($matches2.Count -eq 1) { $script:RepoDir = $matches2[0]; return }
        if ($script:NonInteractive) {
            Warn "Ambiguous: $($matches2.Count) repositories match '$name':"
            foreach ($m in $matches2) { Hint $m }
            Die $EX_NOTFOUND 'Cannot choose without a terminal.' @("Use a longer path suffix (e.g. --component stack/$name) or the full path.")
        }
        Warn "Several repositories match '$name' - pick one:"
        $script:RepoDir = Pick-FromList 'Repository' $matches2
        return
    }

    # No --component given: scan current directory for all git repos (Main Repo + nested components)
    $all = @(Find-Repos $pwdPath)
    if ($all.Count -eq 0 -and $top) {
        $script:RepoDir = $top
        return
    }
    if ($all.Count -eq 0) {
        Die $EX_NOTFOUND "No git repositories found under $pwdPath (depth $($script:MaxDepth))." @('cd to your Main Repo root, or raise GIT_FLOW_MAX_DEPTH')
    }
    if ($all.Count -eq 1) {
        $script:RepoDir = $all[0]
        return
    }

    # Multiple repos found (Main Repo + nested AUTOSAR component repos!)
    $statuses = @(Show-WorkspaceDashboard $pwdPath $all)
    if ($script:NonInteractive) {
        if ($top) { $script:RepoDir = $top; return }
        Die $EX_USAGE 'Multiple repositories found under current folder and no --component given.' @('Pass -c <component-name> (or run interactively to pick from the list)')
    }

    Write-Host ''
    Write-Line "Tip: Type a number (1-$($all.Count)), '2 3' for multi-component branching, 'h' for compact health summary, or 's' to Sync ALL repos." 'Cyan'
    while ($true) {
        $sel = Read-Host "Select repository (1-$($all.Count), e.g. '2 3', name, 'h' = health, 's' = sync all, 'q' = quit)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        $sel = $sel.Trim()
        if ($sel -match '^[qQ]$') { Die $EX_ABORT 'Cancelled.' }
        if ($sel -match '^[hH]$') { Show-WorkspaceHealth $pwdPath $all; Write-Host ''; continue }
        if ($sel -match '^[sS0]$') {
            $script:DoSync = $true
            $script:RepoDir = $all[0]
            return
        }
        $tokens = @($sel -split '[\s,]+' | Where-Object { $_ })
        if ($tokens.Count -gt 1) {
            $chosen = New-Object System.Collections.Generic.List[string]
            $okAll = $true
            foreach ($tok in $tokens) {
                $n = 0
                if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $all.Count) {
                    if (-not $chosen.Contains($all[$n - 1])) { $chosen.Add($all[$n - 1]) }
                } else {
                    $byName = @(Match-Repos $pwdPath $tok)
                    if ($byName.Count -eq 1) {
                        if (-not $chosen.Contains($byName[0])) { $chosen.Add($byName[0]) }
                    } else {
                        Warn "Could not uniquely match '$tok'."
                        $okAll = $false; break
                    }
                }
            }
            if ($okAll -and $chosen.Count -gt 1) {
                $script:MultiRepos = @($chosen.ToArray())
                $script:RepoDir = $script:MultiRepos[0]
                return
            }
            continue
        }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $all.Count) {
            $script:RepoDir = $all[$n - 1]
            return
        }
        $byName = @(Match-Repos $pwdPath $sel)
        if ($byName.Count -eq 1) { $script:RepoDir = $byName[0]; return }
        if ($byName.Count -gt 1) {
            Warn "Multiple repos match '$sel':"
            $script:RepoDir = Pick-FromList 'Repository' $byName
            return
        }
        Warn "No repository matched '$sel'. Enter 1-$($all.Count), '2 3' for multi-component branching, a component name, 's' to sync all, or 'q' to quit."
    }
}

# ------------------------------------------------ .repo & fetch helpers ------
function Invoke-DotRepoFetch([string]$Root) {
    if ($script:NoFetch) { return }
    $candidates = @()
    if ($Root) { $candidates += (Join-Path $Root '.repo') }
    if ($script:WorkspaceRoot -and $script:WorkspaceRoot -ne $Root) { $candidates += (Join-Path $script:WorkspaceRoot '.repo') }
    foreach ($dotRepo in $candidates) {
        if (-not (Test-Path -LiteralPath $dotRepo -PathType Container)) { continue }
        [void](Git-Out -C $dotRepo rev-parse --git-dir)
        if ($script:GitExit -eq 0) {
            Info "Found .repo folder ($dotRepo) -> running 'git fetch --all --prune'..."
            [void](Git-Cap -C $dotRepo fetch --all --prune --quiet)
        }
        $manifests = Join-Path $dotRepo 'manifests'
        if (Test-Path -LiteralPath $manifests -PathType Container) {
            [void](Git-Out -C $manifests rev-parse --git-dir)
            if ($script:GitExit -eq 0) {
                Info "Found .repo/manifests -> running 'git fetch --all --prune'..."
                [void](Git-Cap -C $manifests fetch --all --prune --quiet)
            }
        }
        break
    }
}

function Resolve-RemoteName {
    $script:Remote = $script:DefaultRemote
    if (Git-Ok remote get-url $script:Remote) { return }
    $remotes = @((Git-Out remote) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($remotes.Count -eq 0) {
        Die $EX_STATE "No git remotes are configured in $($script:RepoDir)." @("Add one with: git remote add origin <gitlab-url>")
    }
    if ($script:RemoteExplicit) {
        Die $EX_STATE "Remote '$($script:Remote)' is not configured in $($script:RepoDir)." @("Configured remotes: $($remotes -join ' ')", "Use --remote <name>")
    }
    foreach ($r in $remotes) {
        if (Git-Ok show-ref --verify --quiet "refs/remotes/$r/$($script:BaseBranch)") {
            Info "Remote 'origin' not found; auto-selected remote '$r' (has $($script:BaseBranch))."
            $script:Remote = $r
            return
        }
    }
    $script:Remote = $remotes[0]
    Info "Remote 'origin' not found; auto-selected configured remote '$($script:Remote)'."
}

# ------------------------------------------------------------ preflight -------
function Test-Protected([string]$b) {
    if ($b -in @('main', 'master', 'develop') -or $b -like 'release/*' -or $b -eq $script:BaseBranch) { return $true }
    foreach ($p in $script:ExtraProtected) { if ($b -like $p) { return $true } }
    return $false
}

function Test-RepoState {
    $gd = Git-Out rev-parse --absolute-git-dir
    if ((Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply'))) {
        Die $EX_STATE "A rebase is in progress in $($script:RepoDir)." @('Resolve conflicts, then: git add <files>; git rebase --continue', 'Or back out safely:      git rebase --abort')
    }
    if (Test-Path -LiteralPath (Join-Path $gd 'MERGE_HEAD')) {
        Die $EX_STATE "A merge is in progress in $($script:RepoDir)." @('Resolve conflicts, then: git add <files>; git commit', 'Or back out safely:      git merge --abort')
    }
    if (Test-Path -LiteralPath (Join-Path $gd 'CHERRY_PICK_HEAD')) {
        Die $EX_STATE 'A cherry-pick is in progress.' @('Finish: git cherry-pick --continue', 'Or: git cherry-pick --abort')
    }
    if (Test-Path -LiteralPath (Join-Path $gd 'REVERT_HEAD')) {
        Die $EX_STATE 'A revert is in progress.' @('Finish: git revert --continue', 'Or: git revert --abort')
    }
    if (Git-Out diff --name-only --diff-filter=U) {
        Die $EX_STATE 'Unresolved merge conflicts exist in the working tree.' @('See them: git status', 'Fix, then: git add <files>')
    }
}

function Fail-Network([string]$Out) {
    $remote = $script:Remote
    if ($Out -match 'Permission denied|Authentication failed|could not read Username|returned error: 40[13]|Host key verification failed') {
        Die $EX_NETWORK "Authentication to '$remote' failed." @("SSH: 'ssh -T <git-host>' and 'ssh-add -l' show whether your key is loaded", 'HTTPS: refresh your token / credential manager (re-enter your PAT)', 'Also confirm you have access to this repository on the server')
    }
    if ($Out -match 'Could not resolve host|timed out|Connection refused|Network is unreachable|unable to access') {
        Die $EX_NETWORK "Cannot reach '$remote' (network/DNS/proxy)." @('Are you on the VPN? Is the proxy configured (git config --get http.proxy)?', 'Work offline with --no-fetch (pushing still needs network)')
    }
    $tail = (($Out -split "`n" | Select-Object -Last 3) -join ' ')
    Die $EX_NETWORK "Fetching from '$remote' failed." @("git said: $tail")
}

function Initialize-GitEnv {
    $cfg = Git-Out config --get core.sshCommand
    if (-not $env:GIT_SSH_COMMAND -and -not $env:GIT_SSH -and -not $cfg) { $env:GIT_SSH_COMMAND = 'ssh -o ConnectTimeout=20' }
    if ($script:NonInteractive) { $env:GIT_TERMINAL_PROMPT = '0' }
}

function Invoke-Preflight {
    Step 'Pre-flight checks'
    if (-not (Git-Ok rev-parse --is-inside-work-tree)) {
        Die $EX_STATE "'$($script:RepoDir)' is not a valid git working tree." @('Is the submodule initialised? git submodule update --init')
    }
    Test-RepoState
    [void](Git-Out symbolic-ref -q HEAD)
    if ($script:GitExit -eq 0) {
        $script:Detached = $false; $script:CurBranch = Git-Out symbolic-ref --short HEAD
    } else { $script:Detached = $true; $script:CurBranch = '' }
    if (-not (Git-Ok rev-parse --verify -q HEAD)) {
        Die $EX_STATE 'This repository has no commits yet.' @('Make an initial commit or clone from the remote first.')
    }
    Resolve-RemoteName
    Ok 'Repository state is clean (no rebase/merge/cherry-pick in progress).'
    if ($script:NoFetch) {
        Warn 'Skipping fetch (--no-fetch): remote refs may be stale.'
    } else {
        Invoke-DotRepoFetch $script:WorkspaceRoot
        Info "Running 'git fetch --all --prune' in $($script:RepoDir)..."
        $out = Git-Cap fetch --all --prune --quiet
        if ($script:GitExit -ne 0) { Fail-Network $out }
        Resolve-RemoteName
        Ok "All remotes fetched and refs up to date (using remote '$($script:Remote)')."
    }
}

function Show-CategorizedChanges {
    $raw = Git-Out -c core.quotepath=off status --porcelain
    $lines = @($raw -split "`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) {
        Ok 'Working tree clean.'
        return
    }
    $rhapsody = New-Object System.Collections.Generic.List[string]
    $autosar  = New-Object System.Collections.Generic.List[string]
    $deleted  = New-Object System.Collections.Generic.List[string]
    $other    = New-Object System.Collections.Generic.List[string]

    foreach ($ln in $lines) {
        if ($ln.Length -lt 4) { continue }
        $st = $ln.Substring(0, 2)
        $path = $ln.Substring(3).Trim()
        if ($path -match ' -> (.+)$') { $path = $Matches[1] }
        $path = $path.Trim('"')
        $tag = $st.Trim()
        if ($st -match 'D') {
            $deleted.Add("[$tag] $path")
        } elseif ($path -imatch '\.(rpwx|rpy|sbsx|sbs|cls|clsx|cmp|cmpx|omd|omdx|msc|mscx|ucd|ucdx|hep|prp|rpl|rplx)$') {
            $rhapsody.Add("[$tag] $path")
        } elseif ($path -imatch '\.(arxml|dbc|ldf|a2l|cdd|odx|pdx|ecuc|dpa|dcf)$') {
            $autosar.Add("[$tag] $path")
        } else {
            $other.Add("[$tag] $path")
        }
    }

    if ($rhapsody.Count -gt 0) {
        Write-Host ''
        Write-Line "  Rhapsody Changes ($($rhapsody.Count)):" 'Cyan'
        foreach ($f in $rhapsody) { Write-Host "    $f" }
    }
    if ($autosar.Count -gt 0) {
        Write-Host ''
        Write-Line "  AUTOSAR / ARXML Changes ($($autosar.Count)):" 'Yellow'
        foreach ($f in $autosar) { Write-Host "    $f" }
    }
    if ($deleted.Count -gt 0) {
        Write-Host ''
        Write-Line "  Deleted Artifacts ($($deleted.Count)):" 'Red'
        foreach ($f in $deleted) { Write-Host "    $f" }
    }
    if ($other.Count -gt 0) {
        Write-Host ''
        Write-Line "  Source / Other Changes ($($other.Count)):" 'White'
        foreach ($f in $other) { Write-Host "    $f" }
    }
}

function Show-Status {
    Step 'Repository status'
    Info "Repo   : $($script:RepoDir)"
    if ($script:Detached) { Info ('HEAD   : DETACHED at ' + (Git-Out rev-parse --short HEAD) + ' (manifest-managed)') } else { Info "Branch : $($script:CurBranch)" }
    Show-CategorizedChanges
}

function Confirm-BaseRef {
    $ref = "refs/remotes/$($script:Remote)/$($script:BaseBranch)^{commit}"
    if (Git-Ok rev-parse --verify --quiet $ref) { return }
    if (-not $script:NoFetch) {
        Info "Branch '$($script:BaseBranch)' not in local remote-tracking refs yet; fetching '$($script:BaseBranch)' from '$($script:Remote)'..."
        [void](Git-Cap fetch --quiet $script:Remote "+refs/heads/$($script:BaseBranch):refs/remotes/$($script:Remote)/$($script:BaseBranch)")
        if (Git-Ok rev-parse --verify --quiet $ref) {
            Ok "Found '$($script:Remote)/$($script:BaseBranch)' on remote."
            return
        }
    }
    $def = Git-Out symbolic-ref --short "refs/remotes/$($script:Remote)/HEAD"
    if ($script:GitExit -ne 0) { $def = '' }
    $prefix = "$($script:Remote)/"
    if ($def.StartsWith($prefix)) { $def = $def.Substring($prefix.Length) }
    if (-not $def) {
        foreach ($cand in @('develop', 'main', 'master')) {
            if (Git-Ok rev-parse --verify --quiet "refs/remotes/$($script:Remote)/$cand^{commit}") { $def = $cand; break }
        }
    }
    if ($def -and $def -ne $script:BaseBranch -and -not $script:NonInteractive) {
        Warn "Base branch '$($script:BaseBranch)' not found on '$($script:Remote)'; found '$def' on remote."
        if (Confirm-Action "Use '$def' as the base branch for this component?" 'y' $true) { $script:BaseBranch = $def; return }
    }
    $rl = ((Git-Out branch -r) -replace '\s+', ' ')
    if ($rl.Length -gt 300) { $rl = $rl.Substring(0, 300) }
    $h = @('Use --base <branch> or set $env:GIT_FLOW_BASE', "Remote branches: $rl")
    if ($script:NoFetch) { $h += 'You used --no-fetch: refs may be missing; run without it.' }
    Die $EX_NOTFOUND "Base branch '$($script:Remote)/$($script:BaseBranch)' does not exist." $h
}

function Sync-LocalBaseBranch {
    $base = $script:BaseBranch
    $remote = $script:Remote
    $remoteRef = "$remote/$base"
    Step "Syncing local '$base' branch with '$remoteRef'"
    if (Git-Ok show-ref --verify --quiet "refs/heads/$base") {
        if ($script:Detached -or $script:CurBranch -ne $base) {
            Info "Switching to local '$base' branch..."
            $rc = Try-Git @('checkout', $base)
            if ($rc -ne 0) {
                Warn "Could not checkout local '$base' (an untracked file may conflict). Will create branch directly off '$remoteRef'."
                return $false
            }
            $script:CurBranch = $base; $script:Detached = $false
        }
        [void](Git-Cap branch "--set-upstream-to=$remoteRef" $base)
        Info "Pulling latest changes into '$base' (git pull --ff-only $remote $base)..."
        $rc = Try-Git @('pull', '--ff-only', $remote, $base)
        if ($rc -ne 0) {
            Warn "Local '$base' could not be fast-forwarded (it may have local commits). Will create branch directly off '$remoteRef'."
            return $false
        }
        Ok "Local '$base' is checked out and up to date with '$remoteRef'."
        return $true
    } else {
        Info "Local '$base' was not listed in 'git branch' yet (only existed on remote as '$remoteRef')."
        Info "Creating local '$base' tracking '$remoteRef'..."
        $rc = Try-Git @('checkout', '-b', $base, '--track', $remoteRef)
        if ($rc -ne 0) {
            Warn "Could not create local '$base' (an untracked file may conflict). Will create branch directly off '$remoteRef'."
            return $false
        }
        $script:CurBranch = $base; $script:Detached = $false
        Ok "Local '$base' created, checked out, and synced with '$remoteRef'."
        return $true
    }
}

function Invoke-SyncAll([string]$Root) {
    $repos = @(Find-Repos $Root)
    if ($repos.Count -eq 0) {
        Die $EX_NOTFOUND "No git repositories found under $Root."
    }
    Step "Syncing ALL ($($repos.Count)) repositories to latest '$($script:BaseBranch)'"
    Invoke-DotRepoFetch $Root

    $synced = 0; $skipped = 0; $failed = 0
    foreach ($r in $repos) {
        $label = Get-RepoRelativeLabel $Root $r
        Write-Host ''
        Write-Line "--- [$label] ---" 'Cyan'
        Set-Location -LiteralPath $r
        $script:RepoDir = $r
        if (-not (Git-Ok rev-parse --is-inside-work-tree)) {
            Warn "Skipping '$label' (not a valid working tree)."
            $skipped++; continue
        }
        $remotes = @((Git-Out remote) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($remotes.Count -eq 0) {
            Warn "Skipping '$label' (no git remote configured)."
            $skipped++; continue
        }
        $rem = if ($remotes -contains $script:DefaultRemote) { $script:DefaultRemote } else { $remotes[0] }
        if (-not $script:NoFetch) {
            Info "Running 'git fetch --all --prune'..."
            $fo = Git-Cap fetch --all --prune --quiet
            if ($script:GitExit -ne 0) {
                Warn "Fetch failed in '$label': $(($fo -split "`n" | Select-Object -First 1))"
                $failed++; continue
            }
        }
        $base = $script:BaseBranch
        if (-not (Git-Ok rev-parse --verify --quiet "refs/remotes/$rem/$base^{commit}")) {
            if (-not $script:NoFetch) {
                [void](Git-Cap fetch --quiet $rem "+refs/heads/$base:refs/remotes/$rem/$base")
            }
        }
        if (-not (Git-Ok rev-parse --verify --quiet "refs/remotes/$rem/$base^{commit}")) {
            Warn "Remote '$rem' does not have branch '$base' in '$label' - fetched remotes only."
            $skipped++; continue
        }
        $dirty = Git-Out status --porcelain --untracked-files=no
        if ($dirty) {
            Warn "Has uncommitted tracked changes - fetched latest refs, kept current branch untouched."
            $skipped++; continue
        }
        $cur = Git-Out symbolic-ref --short -q HEAD
        if ($cur -and $cur -ne $base -and -not (Test-Protected $cur)) {
            Warn "Currently on active work branch '$cur' - fetched latest refs, kept branch '$cur' checked out."
            $skipped++; continue
        }
        if (Git-Ok show-ref --verify --quiet "refs/heads/$base") {
            if ($cur -ne $base) {
                if ((Try-Git @('checkout', $base)) -ne 0) {
                    Warn "Could not switch to '$base' in '$label' (untracked file collision?)."
                    $failed++; continue
                }
            }
            [void](Git-Cap branch "--set-upstream-to=$rem/$base" $base)
            $rc = Try-Git @('pull', '--ff-only', $rem, $base)
            if ($rc -eq 0) {
                Ok "'$label' is now on '$base' and up to date with '$rem/$base'."
                $synced++
            } else {
                Warn "Could not fast-forward '$base' in '$label'."
                $failed++
            }
        } else {
            $rc = Try-Git @('checkout', '-b', $base, '--track', "$rem/$base")
            if ($rc -eq 0) {
                Ok "'$label' created local '$base' tracking '$rem/$base' and is up to date."
                $synced++
            } else {
                Warn "Could not checkout '$base' in '$label'."
                $failed++
            }
        }
    }
    Step "Workspace Sync Summary"
    Ok "Synced to '$($script:BaseBranch)': $synced   |   Kept as-is (dirty/feature branch): $skipped   |   Failed: $failed"
}

# ------------------------------------------------- input collection -----------
function ConvertTo-BranchDesc([string]$d) {
    $s = ($d.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s.Length -gt 50) { $s = $s.Substring(0, 50).TrimEnd('-') }
    return $s
}

function Detect-JiraId {
    # 1) Current branch name (e.g. feature/OSKDC33837-14809-ucl-10-02)
    if ($script:CurBranch) {
        $m = [regex]::Match($script:CurBranch, $script:JiraPattern)
        if ($m.Success) { return @{ Id = $m.Value; Source = "current branch '$($script:CurBranch)'" } }
    }
    # 2) Changed / untracked filenames
    $files = Git-Out -c core.quotepath=off status --porcelain
    if ($files) {
        $m = [regex]::Match($files, $script:JiraPattern)
        if ($m.Success) { return @{ Id = $m.Value; Source = 'changed file name' } }
    }
    # 3) Added/modified lines in staged or unstaged diff (capped at 500 lines for speed on large .sbsx models)
    foreach ($diffArgs in @(@('diff', '--cached', '-U0'), @('diff', '-U0'))) {
        $d = Git-Out @diffArgs
        if (-not $d) { continue }
        $added = @($d -split "`n" | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') } | Select-Object -First 500)
        foreach ($ln in $added) {
            $m = [regex]::Match($ln, $script:JiraPattern)
            if ($m.Success) { return @{ Id = $m.Value; Source = 'changed file contents' } }
        }
    }
    return $null
}

function Read-BranchInputs {
    if (-not $script:JiraId) {
        $detected = Detect-JiraId
        if ($script:JiraFromBranch) {
            if ($detected) {
                $script:JiraId = $detected.Id
                Info "Auto-detected Jira ID '$($script:JiraId)' from $($detected.Source) (--jira-from-branch)."
            } else {
                Die $EX_USAGE 'Could not extract a Jira ID from current branch or changed files.' @('Pass --jira OSKDC33837-14809 explicitly')
            }
        } elseif ($detected -and -not $script:NonInteractive) {
            Info "Auto-detected Jira ID '$($detected.Id)' from $($detected.Source) (press Enter to use it)."
            $script:LastJiraId = $detected.Id
        }
    }

    $tries = 0
    while ($true) {
        if (-not $script:JiraId) {
            $v = Read-Value 'Jira Task ID (e.g. OSKDC33837-14809)' $script:LastJiraId
            if ($null -eq $v) { Die $EX_USAGE 'Missing Jira ID.' @('Pass --jira OSKDC33837-14809 or --jira-from-branch') }
            $script:JiraId = $v
        }
        $script:JiraId = $script:JiraId.Trim().ToUpperInvariant()
        if ($script:JiraId -cmatch $script:JiraRegex) { $script:LastJiraId = $script:JiraId; break }
        if ($script:NonInteractive) { Die $EX_USAGE "Invalid Jira ID '$($script:JiraId)'." @('Expected a key like OSKDC33837-14809 (LETTERS-NUMBER)') }
        Warn "Invalid Jira ID '$($script:JiraId)' - expected something like OSKDC33837-14809."
        $script:JiraId = ''; $tries++
        if ($tries -ge 3) { Die $EX_USAGE 'Too many invalid Jira IDs.' }
    }

    if (-not $script:BranchType) {
        if ($script:NonInteractive) {
            $script:BranchType = 'none'
            Info "No --type given; defaulting to 'none' (direct Jira ID + title)."
        } else {
            Write-Host 'Select branch prefix / type:'
            Write-Host "  [1] none     (direct Jira ID + title: $($script:JiraId)-your-title)"
            Write-Host "  [2] feature  (feature/$($script:JiraId)-your-title)"
            Write-Host "  [3] bugfix   (bugfix/$($script:JiraId)-your-title)"
            Write-Host "  [4] hotfix   (hotfix/$($script:JiraId)-your-title)"
            $v = Read-Value 'Enter number' '1'
            switch ($v.ToLowerInvariant()) {
                { $_ -in @('1', 'none', 'direct', 'jira') } { $script:BranchType = 'none' }
                { $_ -in @('2', 'feature') } { $script:BranchType = 'feature' }
                { $_ -in @('3', 'bugfix') } { $script:BranchType = 'bugfix' }
                { $_ -in @('4', 'hotfix') } { $script:BranchType = 'hotfix' }
                default { Warn "Unrecognised choice; using 'none' (direct Jira ID + title)."; $script:BranchType = 'none' }
            }
        }
    }

    $tries = 0
    while ($true) {
        if (-not $script:Desc) {
            $v = Read-Value 'Branch title / short description (required, e.g. update-can-parser)'
            if ($null -eq $v) { Die $EX_USAGE 'Missing branch title / description.' @('Pass --desc "short description"') }
            $script:Desc = $v
        }
        $script:Sanitized = ConvertTo-BranchDesc $script:Desc
        if ($script:Sanitized) { break }
        if ($script:NonInteractive) { Die $EX_USAGE "Branch title '$($script:Desc)' has no letters or digits." @('Pass --desc "short description"') }
        Warn 'Branch title / description is required and must contain letters or digits.'
        $script:Desc = ''; $tries++
        if ($tries -ge 3) { Die $EX_USAGE 'Too many invalid branch descriptions.' }
    }

    $coreName = "$($script:JiraId)-$($script:Sanitized)"
    $script:BranchName = if ($script:BranchType -eq 'none') { $coreName } else { "$($script:BranchType)/$coreName" }
    if (-not (Git-Ok check-ref-format --branch $script:BranchName)) {
        Die $EX_USAGE "'$($script:BranchName)' is not a valid git branch name." @('Change --desc')
    }
    Info "Branch name: $($script:BranchName)"
}

function Test-BranchFree {
    if (Git-Ok show-ref --verify --quiet "refs/heads/$($script:BranchName)") {
        if (-not $script:NonInteractive) {
            Warn "Branch '$($script:BranchName)' already exists locally."
            if (Confirm-Action "Switch to existing local branch '$($script:BranchName)' instead?" 'y' $false) {
                Run-Git @('checkout', $script:BranchName)
                $script:CurBranch = $script:BranchName; $script:Detached = $false
                return $false
            }
        }
        Die $EX_STATE "Branch '$($script:BranchName)' already exists locally." @("Continue on it:   git checkout $($script:BranchName)", 'Or choose a different --desc')
    }
    if (Git-Ok show-ref --verify --quiet "refs/remotes/$($script:Remote)/$($script:BranchName)") {
        if (-not $script:NonInteractive) {
            Warn "Branch '$($script:BranchName)' already exists on '$($script:Remote)'."
            if (Confirm-Action "Check out and track existing remote branch '$($script:Remote)/$($script:BranchName)'?" 'y' $false) {
                Run-Git @('checkout', '-b', $script:BranchName, '--track', "$($script:Remote)/$($script:BranchName)")
                $script:CurBranch = $script:BranchName; $script:Detached = $false
                return $false
            }
        }
        Die $EX_STATE "Branch '$($script:BranchName)' already exists on '$($script:Remote)'." @("Check it out:  git checkout -b $($script:BranchName) $($script:Remote)/$($script:BranchName)", 'Or choose a different --desc')
    }
    return $true
}

# ------------------------------------------------------- action: branch ------
function Protect-DirtyTree {
    $script:CarryChanges = $false
    $changes = Git-Out status --porcelain --untracked-files=no
    if (-not $changes) { return }
    Warn 'Uncommitted changes detected in tracked files:'
    Git-Show status -s --untracked-files=no
    if ($script:CarryFlag) {
        Info 'Carrying uncommitted changes to the new branch (--carry).'
        $script:CarryChanges = $true
        return
    }
    if ($script:AutoStash) {
        $script:StashMsg = "git_flow auto-stash $(Get-Date -Format 'yyyyMMdd-HHmmss') before $($script:BranchName)"
        Run-Git @('stash', 'push', '-m', $script:StashMsg)
        if (-not $script:DryRun) { $script:StashCreated = $true }
        Ok 'Changes stashed.'
        return
    }
    if ($script:NonInteractive) {
        Die $EX_STATE 'Uncommitted changes detected in tracked files.' @('Pass --carry to carry them onto the new branch, or --stash to stash them first')
    }
    Write-Host ''
    Write-Host 'How would you like to handle these uncommitted changes?'
    Write-Host '  [1] Carry changes to new branch (recommended - keeps modified files untouched)'
    Write-Host "  [2] Stash changes and create clean branch off latest $($script:BaseBranch)"
    Write-Host '  [3] Cancel'
    $ch = Read-Value 'Enter choice' '1'
    switch ($ch.ToLowerInvariant()) {
        { $_ -in @('1', 'carry') } {
            $script:CarryChanges = $true
            Info 'Will carry your uncommitted changes onto the new branch.'
        }
        { $_ -in @('2', 'stash') } {
            $script:StashMsg = "git_flow auto-stash $(Get-Date -Format 'yyyyMMdd-HHmmss') before $($script:BranchName)"
            Run-Git @('stash', 'push', '-m', $script:StashMsg)
            if (-not $script:DryRun) { $script:StashCreated = $true }
            Ok 'Changes stashed.'
        }
        { $_ -in @('3', 'cancel', 'q', 'quit') } {
            Die $EX_ABORT 'Cancelled - no branch was created and your files were not touched.'
        }
        default {
            Warn "Unrecognised choice; carrying changes to the new branch."
            $script:CarryChanges = $true
        }
    }
}

function Protect-DetachedHead {
    $sha = Git-Out rev-parse --short HEAD
    $reach = Git-Out for-each-ref --contains HEAD --count=1 refs/heads refs/remotes refs/tags
    if (-not $reach) {
        Warn "HEAD is detached at $sha and those commits are not on any branch - leaving would orphan them."
        $rescue = "rescue/detached-$sha"
        if (Confirm-Action "Create safety branch '$rescue' to keep them?" 'y' $true) {
            Run-Git @('branch', $rescue)
            Ok "Kept your commits on '$rescue'."
        } else {
            Die $EX_STATE 'Aborted to avoid orphaning commits.' @('Keep them: git branch rescue/my-work')
        }
    } else {
        Info "Detached HEAD at $sha (commits are reachable from other refs - safe to leave)."
    }
}

function Invoke-Branch {
    Confirm-BaseRef
    Read-BranchInputs
    if (-not (Test-BranchFree)) {
        Ok "Now on existing branch $($script:BranchName)."
        return
    }
    if ($script:Detached) { Protect-DetachedHead }
    Protect-DirtyTree
    if ($script:CarryChanges) {
        Step "Creating branch '$($script:BranchName)' (carrying uncommitted changes)"
        Run-Git @('checkout', '-b', $script:BranchName)
        Ok "Now on $($script:BranchName) (your uncommitted changes were carried over safely without touching files on disk)."
        $behindBase = [int](Git-Out rev-list --count "HEAD..$($script:Remote)/$($script:BaseBranch)" --)
        if ($behindBase -gt 0) {
            Info "Note: Your current base is $behindBase commit(s) behind $($script:Remote)/$($script:BaseBranch)."
            Hint "After committing your changes, you can run [7] Update branch with latest $($script:BaseBranch) before pushing."
        }
    } else {
        $syncedLocal = Sync-LocalBaseBranch
        Step "Creating branch '$($script:BranchName)'"
        if ($syncedLocal) {
            Run-Git @('checkout', '-b', $script:BranchName)
        } else {
            Run-Git @('checkout', '-b', $script:BranchName, '--no-track', "$($script:Remote)/$($script:BaseBranch)")
        }
        Ok "Now on $($script:BranchName) (branched from latest $($script:BaseBranch))."
    }
    Write-Host ''
    Write-Host 'Next:  edit/review code, then run from Main Repo:'
    Write-Host '  .\git_flow.bat'
}

# --------------------------------------------- rescue / protected handling ----
function Move-WorkToBranch([string]$Reason) {
    $where = if ($script:CurBranch) { $script:CurBranch } else { 'DETACHED HEAD' }
    $det = Detect-JiraId
    $recJira = if ($script:JiraId) { $script:JiraId } elseif ($det) { $det.Id } elseif ($script:LastJiraId) { $script:LastJiraId } else { 'OSKDC33837-14809' }
    Write-Host ''
    Write-Line '================================================================' 'Red'
    Write-Line '  WARNING: Protected Branch / Detached HEAD Detected!' 'Red'
    Write-Line "  You are currently on:   $where" 'Yellow'
    Write-Line "  Creating a commit directly on '$where' is NOT RECOMMENDED / BLOCKED." 'Yellow'
    Write-Line "  Recommended branch:     ${recJira}-short-description" 'Cyan'
    Write-Line '================================================================' 'Red'
    Warn $Reason
    $pending = Git-Out status --porcelain
    $ahead = 0
    if (-not $script:Detached -and (Git-Ok show-ref --verify --quiet "refs/remotes/$($script:Remote)/$($script:CurBranch)")) {
        $ahead = [int](Git-Out rev-list --count "$($script:Remote)/$($script:CurBranch)..HEAD" --)
    }
    if (-not $pending -and $ahead -eq 0 -and -not $script:Detached) {
        Die $EX_PROTECTED "You are on protected branch '$($script:CurBranch)' with nothing to move." @("Start new work with:  $($script:Self) --branch --jira $recJira --desc `"short description`"")
    }
    if ($script:NonInteractive -and (-not $script:JiraId -or -not $script:Desc)) {
        Die $EX_PROTECTED "Refusing to commit/push on '$where'." @("Re-run with --jira $recJira --desc `"title`" (and optional --type) to move your work to a new branch automatically", "Or create it yourself: git checkout -b ${recJira}-short-desc")
    }
    if (-not (Confirm-Action "Create a new Jira branch and move your current work (uncommitted changes + $ahead local commit(s)) onto it now?" 'y' $true)) {
        Die $EX_PROTECTED 'Aborted - nothing was changed.' @("Create a branch first: git checkout -b ${recJira}-short-desc")
    }
    Read-BranchInputs
    if (Test-BranchFree) {
        if ($ahead -gt 0) {
            Warn "$ahead local commit(s) on '$($script:CurBranch)' move into the new branch. Local '$($script:CurBranch)' stays ahead of $($script:Remote)."
            Hint "After your MR merges, realign it:  git checkout $($script:CurBranch); git reset --hard $($script:Remote)/$($script:CurBranch)"
        }
        Run-Git @('checkout', '-b', $script:BranchName)
    }
    $script:CurBranch = $script:BranchName; $script:Detached = $false
    Ok "Work moved to $($script:BranchName)."
}

function Confirm-WorkBranch {
    if ($script:Detached) { Move-WorkToBranch 'HEAD is detached - commits made here are easily lost.' }
    elseif (Test-Protected $script:CurBranch) { Move-WorkToBranch "'$($script:CurBranch)' is a protected branch - direct commits/pushes are blocked." }
}

function Test-BranchConvention {
    if ($script:CurBranch -cmatch $script:BranchRegex) { return }
    Warn "Branch '$($script:CurBranch)' does not match <JIRA-ID>-<title> or <feature|bugfix|hotfix>/<JIRA-ID>-<title>."
    Hint "Pipelines/MR rules may reject it. Rename: git branch -m $($script:CurBranch) PROJ-123-short-desc"
    if ($script:Force) { Warn 'Continuing because of --force.'; return }
    if (Confirm-Action 'Continue anyway?' 'n' $false) { return }
    Die $EX_STATE 'Stopped: branch name violates the naming convention.' @('Rename it (see above) or pass --force')
}

function Resolve-CommitJira {
    $fromBranch = ''
    $m = [regex]::Match($script:CurBranch, $script:JiraPattern)
    if ($m.Success) { $fromBranch = $m.Value }
    if ($script:JiraId) {
        $script:JiraId = $script:JiraId.Trim().ToUpperInvariant()
        if ($script:JiraId -cnotmatch $script:JiraRegex) { Die $EX_USAGE "Invalid Jira ID '$($script:JiraId)'." @('Expected a key like PROJ-123') }
        if ($fromBranch -and $fromBranch -ne $script:JiraId) {
            Warn "Branch '$($script:CurBranch)' is for $fromBranch but you passed $($script:JiraId)."
            if (-not $script:Force -and -not (Confirm-Action "Commit under $($script:JiraId) anyway?" 'n' $false)) {
                Die $EX_USAGE 'Jira ID mismatch - stopped to avoid a mis-linked commit.' @("Use --jira $fromBranch, or rename the branch, or pass --force")
            }
        }
    } elseif ($fromBranch) {
        $script:JiraId = $fromBranch
        Info "Jira ID auto-detected from branch: $($script:JiraId)"
    } else {
        $v = Read-Value 'Jira Task ID (e.g. PROJ-123)' $script:LastJiraId
        if ($null -eq $v) { Die $EX_USAGE "Cannot infer a Jira ID from branch '$($script:CurBranch)'." @('Pass --jira PROJ-123') }
        $script:JiraId = $v.ToUpperInvariant()
    }
    if ($script:JiraId -cnotmatch $script:JiraRegex) { Die $EX_USAGE "Invalid Jira ID '$($script:JiraId)'." @('Expected a key like PROJ-123') }
    $script:LastJiraId = $script:JiraId
}

function Format-CommitMessage {
    $m = $script:CommitMsg
    $tries = 0
    while ($true) {
        if (-not $m) {
            $v = Read-Value "Commit description ($($script:JiraId) will be added automatically)"
            if ($null -eq $v) { Die $EX_USAGE 'Commit message is empty.' @('Pass --commit "description"') }
            $m = $v
        }
        $m = ($m -replace '\s+', ' ').Trim()
        if ($m -imatch ('^\[?(' + $script:JiraPattern + ')\]?(?:\s*[:\-]\s*|\s+|$)(.*)$')) {
            $key = $Matches[1].ToUpperInvariant()
            $rest = $Matches[2].Trim()
            if ($key -ne $script:JiraId) {
                Die $EX_USAGE "Commit message has a different Jira ID ($key) than the branch ($($script:JiraId))." @('Fix the message or --jira')
            }
            $m = $rest
        }
        if ($m) { break }
        if ($script:NonInteractive) {
            Die $EX_USAGE "Commit message must include a description after $($script:JiraId)." @('Pass --commit "what you changed"')
        }
        Warn "Commit message cannot be just the Jira ID - please add a description of what changed."
        $m = ''; $tries++
        if ($tries -ge 3) { Die $EX_USAGE 'Too many empty commit descriptions.' }
    }
    $script:FormattedMsg = "$($script:JiraId): $m"
    if ($script:FormattedMsg.Length -gt 72) { Warn "Commit subject is $($script:FormattedMsg.Length) chars (>72); consider shortening." }
}

function Get-CandidateFiles {
    if ($script:HasStaged) { $t = Git-Out -c core.quotepath=off diff --cached --name-only }
    else {
        $a = Git-Out -c core.quotepath=off ls-files -m
        $b = Git-Out -c core.quotepath=off ls-files -o --exclude-standard
        $t = ($a + "`n" + $b)
    }
    return @($t -split "`n" | Where-Object { $_ })
}

function Test-SensitiveFiles {
    $bad = @(Get-CandidateFiles | Where-Object { $_ -match '(^|/)(\.env(\..+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|p12|pfx|jks|keystore|key))$' -and $_ -notmatch '\.(example|sample|template|dist)$' })
    if ($bad.Count -eq 0) { return }
    Warn 'Files that look like secrets are about to be committed:'
    foreach ($f in $bad) { Write-Host "       $f" }
    if ($script:Force) { Warn 'Continuing because of --force.'; return }
    if (Confirm-Action 'Commit them anyway?' 'n' $false) { return }
    Die $EX_STATE 'Stopped: possible secrets in the commit.' @('Add them to .gitignore, or stage only what you want: git add <files>', 'Override (not recommended): --force')
}

function Test-UnpushedCommits {
    $n = 0
    if (Git-Ok show-ref --verify --quiet "refs/remotes/$($script:Remote)/$($script:CurBranch)") {
        $n = [int](Git-Out rev-list --count "$($script:Remote)/$($script:CurBranch)..HEAD" --)
    } elseif (Git-Ok rev-parse --verify --quiet "refs/remotes/$($script:Remote)/$($script:BaseBranch)") {
        $n = [int](Git-Out rev-list --count "$($script:Remote)/$($script:BaseBranch)..HEAD" --)
    }
    return ($n -gt 0)
}

function Select-FilesInteractively {
    $files = @(Get-CandidateFiles)
    if ($files.Count -eq 0) { Die $EX_STATE 'No modified or untracked files found to stage.' }
    Write-Host ''
    Info 'Select specific files to stage for this commit:'
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $files[$i])
    }
    while ($true) {
        $sel = Read-Host "Enter file numbers separated by space/comma (e.g. 1 3, 'a' = all, 'q' = quit)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        $sel = $sel.Trim()
        if ($sel -match '^[qQ]$') { Die $EX_ABORT 'Cancelled.' }
        if ($sel -match '^[aA]$') {
            Run-Git @('add', '-A')
            $script:HasStaged = $true
            return
        }
        $chosen = @()
        $tokens = @($sel -split '[\s,]+' | Where-Object { $_ })
        $valid = $true
        foreach ($t in $tokens) {
            $n = 0
            if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
                $chosen += $files[$n - 1]
            } else {
                $valid = $false; break
            }
        }
        if ($valid -and $chosen.Count -gt 0) {
            $addArgs = @('add', '--') + $chosen
            Run-Git $addArgs
            $script:HasStaged = $true
            Info 'Staged selected files:'
            Git-Show diff --cached --stat
            return
        }
        Warn "Please enter numbers between 1 and $($files.Count) (e.g. 1 2), 'a' for all, or 'q' to quit."
    }
}

function Get-RhapsodyModelFiles {
    $raw = Git-Out -c core.quotepath=off status --porcelain
    $lines = @($raw -split "`n" | Where-Object { $_.Trim() })
    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        if ($ln.Length -lt 4) { continue }
        $p = $ln.Substring(3).Trim()
        if ($p -match ' -> (.+)$') { $p = $Matches[1] }
        $p = $p.Trim('"')
        if ($p -imatch '\.(rpwx|sbsx|rpy)$') {
            if (-not $matched.Contains($p)) { $matched.Add($p) }
        }
    }
    return @($matched.ToArray())
}

function Invoke-StageAndCommit {
    Step 'Commit'
    if (-not (Git-Out config user.email) -or -not (Git-Out config user.name)) {
        Die $EX_STATE 'git user.name / user.email are not configured.' @('git config user.name "Your Name"', 'git config user.email you@company.com')
    }
    [void](Git-Out diff --cached --quiet)
    $script:HasStaged = ($script:GitExit -eq 1)
    $pending = Git-Out status --porcelain
    if (-not $script:HasStaged -and -not $pending) {
        if ($script:DoPush -and (Test-UnpushedCommits)) { Info 'Nothing new to commit - will push the existing commits.'; return }
        Die $EX_STATE 'Nothing to commit - working tree is clean.' @('Edit files first, or use --push on its own to push existing commits.')
    }
    Format-CommitMessage
    if ($script:HasStaged) {
        Info 'Committing what is already staged (other edits are left out):'
        Git-Show diff --cached --stat
    } else {
        Info 'Nothing staged yet. Changes in this component:'
        Show-CategorizedChanges
        $modelFiles = @(Get-RhapsodyModelFiles)
        if ($script:ModelOnly) {
            if ($modelFiles.Count -eq 0) {
                Die $EX_STATE 'No Rhapsody model files (*.rpwx, *.sbsx, *.rpy) found to commit (--model-only).'
            }
            Info "Staging $($modelFiles.Count) Rhapsody model file(s) only (--model-only)..."
            Run-Git (@('add', '--') + $modelFiles)
            $script:HasStaged = $true
        } elseif ($script:StageAll) {
            Test-SensitiveFiles
            Run-Git @('add', '-A')
            $script:HasStaged = $true
        } elseif ($script:NonInteractive) {
            Die $EX_STATE 'Nothing staged.' @('Stage selectively: git add <files>, or pass --all or --model-only')
        } else {
            Write-Host ''
            Write-Host 'How would you like to stage files for this commit?'
            Write-Host '  [1] Commit ALL changes (git add -A)'
            if ($modelFiles.Count -gt 0) {
                Write-Host "  [2] Commit Rhapsody model files only ($($modelFiles.Count) file(s): *.rpwx, *.sbsx, *.rpy - skips .bak/.tmp/generated)"
                Write-Host '  [3] Pick specific files from a numbered list'
            } else {
                Write-Host '  [2] Pick specific files from a numbered list'
            }
            Write-Host '  [q] Cancel'
            $sc = Read-Value 'Enter choice' '1'
            if ($sc -match '^[qQ]$') { Die $EX_ABORT 'Cancelled.' }
            if ($sc -eq '1') {
                Test-SensitiveFiles
                Run-Git @('add', '-A')
                $script:HasStaged = $true
            } elseif ($sc -eq '2' -and $modelFiles.Count -gt 0) {
                Info "Staging $($modelFiles.Count) Rhapsody model file(s) only:"
                foreach ($mf in $modelFiles) { Write-Host "       $mf" }
                Run-Git (@('add', '--') + $modelFiles)
                $script:HasStaged = $true
            } elseif (($sc -eq '3' -and $modelFiles.Count -gt 0) -or ($sc -eq '2' -and $modelFiles.Count -eq 0)) {
                Select-FilesInteractively
            } else {
                Die $EX_USAGE "Invalid choice '$sc'."
            }
        }
    }
    Test-SensitiveFiles
    Info "Committing: `"$($script:FormattedMsg)`""
    $tmp = [System.IO.Path]::GetTempFileName(); $script:TempFiles.Add($tmp)
    [System.IO.File]::WriteAllText($tmp, $script:FormattedMsg + "`n", (New-Object System.Text.UTF8Encoding $false))
    if ($script:DryRun) {
        Write-Line ("  [dry-run] would run: git commit -m " + (Format-Arg $script:FormattedMsg)) 'Yellow'
        $script:SimCommit = $true; Ok 'Committed.'
    } else {
        $rc = Try-Git @('commit', '-F', $tmp)
        if ($rc -ne 0) {
            Die $EX_GIT 'Commit failed (pre-commit hook, empty commit or config problem).' @('Read the output above; your changes are still staged - fix and re-run the same command')
        }
        Ok 'Committed.'
    }
}

# ------------------------------------------------------------ push / MR ------
function Get-MrBodyTemplate {
    $t = @'
## Summary
<!-- What changed and why (1-3 sentences) -->

## Jira
- Ticket: {{JIRA}}

## Branch
- `{{BRANCH}}` -> `{{BASE}}`

## Commits ({{NCOMMITS}})
{{COMMITS}}

## Files changed
```
{{STAT}}
```

## How to test
- [ ] <!-- steps / evidence -->

## Checklist
- [ ] Branch name and commit messages carry the Jira ID
- [ ] Rebased/merged on latest `{{BASE}}`, no conflicts
- [ ] Builds and tests pass locally
- [ ] Pipeline is green
'@
    return $t
}

function Read-MrPeople {
    if ($script:MrPeoplePrompted -or $script:NonInteractive -or $script:MrMode -eq 'none') { return }
    $script:MrPeoplePrompted = $true
    if (-not $script:Assignee) {
        $v = Read-Value 'GitLab Assignee CDS ID (optional, e.g. jfernan1 - Enter to skip)' $script:LastAssignee
        if ($v) { $script:Assignee = $v; $script:LastAssignee = $v }
    }
    if (-not $script:Reviewer) {
        $v = Read-Value 'GitLab Reviewer CDS ID(s) (optional, e.g. rkumar2 or "rkumar2 asmith3" - Enter to skip)' $script:LastReviewer
        if ($v) { $script:Reviewer = $v; $script:LastReviewer = $v }
    }
}

function Format-GitLabHandles([string]$Raw) {
    $ids = @($Raw -split '[\s,]+' | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ })
    return @($ids | ForEach-Object { '@' + $_ })
}

function Build-MrMetadata {
    $remote = $script:Remote; $baseRef = "$remote/$($script:BaseBranch)"
    $gd = Git-Out rev-parse --absolute-git-dir
    $jira = $script:JiraId
    if (-not $jira) { $m = [regex]::Match($script:CurBranch, $script:JiraPattern); if ($m.Success) { $jira = $m.Value } }
    $n = 0
    $cnt = Git-Out rev-list --count "$baseRef..HEAD" --
    if ($script:GitExit -eq 0 -and $cnt) { $n = [int]$cnt }
    if ($script:SimCommit) { $n++ }
    $commits = Git-Out log --reverse '--format=- %s (`%h`)' "$baseRef..HEAD" --
    if ($script:GitExit -ne 0) { $commits = '' }
    $stat = Git-Out diff --stat=100 "$baseRef...HEAD" --
    if ($script:GitExit -ne 0) { $stat = '' }
    if (-not $stat) {
        $stat = Git-Out status --short
        if ($stat) { $stat = "(uncommitted - would be included)`n$stat" }
    }
    if (-not $stat) { $stat = "(no changes vs $baseRef)" }
    $lines = @($stat -split "`n")
    if ($lines.Count -gt 41) {
        $stat = (($lines | Select-Object -First 40) -join "`n") + "`n... ($($lines.Count - 41) more files)`n" + $lines[-1]
    }
    if (-not $commits) { $commits = '- ' + $(if ($script:FormattedMsg) { $script:FormattedMsg } else { '_(none yet)_' }) }
    $jiraLine = if ($jira) { $jira } else { 'UNKNOWN' }
    if ($jira -and $script:JiraUrl) { $jiraLine = "[$jira]($($script:JiraUrl.TrimEnd('/'))/browse/$jira)" }
    $leaf = $script:CurBranch; $slash = $leaf.IndexOf('/')
    if ($slash -ge 0) { $leaf = $leaf.Substring($slash + 1) }
    if ($jira -and $leaf -eq $jira) { $leaf = '' }
    elseif ($jira -and $leaf.StartsWith("$jira-")) { $leaf = $leaf.Substring($jira.Length + 1) }
    $human = $leaf.Replace('-', ' ')
    if ($human.Length -gt 0) { $human = $human.Substring(0, 1).ToUpperInvariant() + $human.Substring(1) }
    $subj = Git-Out log -1 --format=%s
    if ($script:SimCommit) { $subj = $script:FormattedMsg }
    if (($n -le 1 -or -not $human) -and $subj -and $jira -and $subj.StartsWith("${jira}:")) { $script:MrTitle = $subj }
    elseif ($human) {
        $hj = if ($jira) { $jira } else { 'UNKNOWN' }
        $script:MrTitle = "${hj}: $human"
    } else {
        $script:MrTitle = if ($subj) { $subj } elseif ($jira) { $jira } else { $script:CurBranch }
    }
    $body = Get-MrBodyTemplate
    $body = $body.Replace('{{JIRA}}', $jiraLine).Replace('{{BRANCH}}', $script:CurBranch).Replace('{{BASE}}', $script:BaseBranch)
    $body = $body.Replace('{{NCOMMITS}}', [string]$n).Replace('{{COMMITS}}', $commits).Replace('{{STAT}}', $stat).TrimEnd()
    $qa = @()
    if ($script:Assignee) {
        $ah = @(Format-GitLabHandles $script:Assignee)
        if ($ah.Count -gt 0) { $qa += ('/assign ' + ($ah -join ' ')) }
    }
    if ($script:Reviewer) {
        $rh = @(Format-GitLabHandles $script:Reviewer)
        if ($rh.Count -gt 0) { $qa += ('/assign_reviewer ' + ($rh -join ' ')) }
    }
    if ($qa.Count -gt 0) {
        $body = $body + "`n`n" + ($qa -join "`n")
    }
    $script:MrBody = $body.TrimEnd()
    $script:MrBodyFile = Join-Path $gd 'MR_DESCRIPTION.md'
}

function Fail-Push {
    $out = $script:LastLog
    $remote = $script:Remote; $cur = $script:CurBranch
    if ($out -match 'Permission denied|Authentication failed|could not read Username|returned error: 40[13]') {
        Die $EX_NETWORK "Push failed: authentication/permission problem on '$remote'." @('Refresh your SSH key / token and retry', 'Make sure you have Developer (write) access to this repo')
    }
    if ($out -match 'protected branch|GH006|not allowed to push') {
        Die $EX_PROTECTED 'Push rejected: the server says this branch is protected.' @("Push a feature branch instead and open an MR into $($script:BaseBranch)")
    }
    if ($out -match 'non-fast-forward|fetch first|Updates were rejected') {
        Die $EX_GIT "Push rejected: the remote branch has commits you don't have (diverged)." @("Rebase onto it: git pull --rebase $remote $cur   then re-run with --push", 'Conflicts? fix files -> git add -> git rebase --continue   (or git rebase --abort)', "This script never force-pushes. If you rewrote history on purpose: git push --force-with-lease $remote $cur")
    }
    if ($out -match 'exceeds|File size|too large|large files') {
        Die $EX_GIT 'Push rejected: a file/pack exceeds the server size limit.' @('Find big files: git rev-list --objects --all | sort | tail', 'Remove them from the commit and use Git LFS if needed')
    }
    if ($out -match 'hook declined|remote rejected') {
        Die $EX_GIT 'Push rejected by a server-side hook / policy.' @("Read the 'remote:' lines above - typical causes: branch name, commit message (Jira ID), file rules", 'Fix the commit: git commit --amend -m "PROJ-123: message"  then re-run --push')
    }
    if ($out -match 'Could not resolve host|timed out|Connection') {
        Die $EX_NETWORK 'Push failed: network problem.' @('Check VPN/proxy and retry')
    }
    Die $EX_GIT 'Push failed.' @('Read the git output above.', 'Preview with --dry-run; check: git status, git remote -v')
}

# Checks if the latest local commit is missing the Jira ID prefix before pushing
function Test-UnpushedCommitJira {
    if ($script:DoCommit -or -not $script:JiraId -or $script:NonInteractive) { return }
    $subj = Git-Out log -1 --format=%s
    if (-not $subj) { return }
    if ($subj -imatch ('^\[?' + $script:JiraPattern + '\]?')) { return }
    Warn "Your latest commit message (`"$subj`") does not start with Jira ID '$($script:JiraId):'."
    Hint "GitLab commit hooks may reject a push if the commit message is missing the Jira ID."
    if (Confirm-Action "Automatically prefix '$($script:JiraId): ' to your latest commit before pushing?" 'y' $false) {
        $newMsg = "$($script:JiraId): $subj"
        Run-Git @('commit', '--amend', '-m', $newMsg)
        Ok "Updated commit message to: `"$newMsg`""
    }
}

function Invoke-Push {
    Step 'Push'
    $remote = $script:Remote; $cur = $script:CurBranch; $base = $script:BaseBranch
    if ($script:Detached -or (Test-Protected $cur)) {
        $where = if ($cur) { $cur } else { 'detached HEAD' }
        Die $EX_PROTECTED "Refusing to push '$where' (protected / detached)."
    }
    $ahead = 0; $behind = 0
    if (Git-Ok show-ref --verify --quiet "refs/remotes/$remote/$cur") {
        $counts = (Git-Out rev-list --left-right --count "HEAD...$remote/$cur" --) -split '\s+'
        $ahead = [int]$counts[0]; $behind = [int]$counts[1]
        if ($script:SimCommit) { $ahead++ }
        if ($ahead -gt 0 -and $behind -gt 0) {
            Warn "Branch has diverged from $remote/${cur}: $ahead ahead, $behind behind."
            if (Confirm-Action "Rebase your commits onto $remote/$cur now (git pull --rebase)?" 'n' $false) {
                if ((Try-Git @('pull', '--rebase', $remote, $cur)) -ne 0) {
                    Die $EX_STATE 'Rebase stopped on conflicts.' @('Fix files -> git add <files> -> git rebase --continue   (or: git rebase --abort)', "Then re-run: $($script:Self) --push")
                }
            } else {
                Die $EX_GIT 'Diverged from remote - not pushing.' @("Rebase: git pull --rebase $remote $cur   then re-run with --push", 'Intentional history rewrite? git push --force-with-lease (this script never force-pushes)')
            }
        } elseif ($ahead -eq 0 -and $behind -gt 0) {
            Die $EX_STATE "Remote branch is $behind commit(s) ahead; nothing of yours to push." @("git pull --rebase $remote $cur")
        } elseif ($ahead -eq 0) {
            Info "Branch already up to date on '$remote' - nothing to push."
            return
        }
    } else {
        $ahead = [int](Git-Out rev-list --count "$remote/$base..HEAD" --)
        if ($script:SimCommit) { $ahead++ }
        if ($ahead -eq 0) {
            Die $EX_STATE "No commits beyond $remote/$base - an MR would be empty." @("Commit first: $($script:Self) --commit `"message`"")
        }
    }

    Test-UnpushedCommitJira

    $behindBase = [int](Git-Out rev-list --count "HEAD..$remote/$base" --)
    if ($behindBase -gt 0) {
        Warn "Branch is $behindBase commit(s) behind $remote/$base."
        [void](Git-Cap merge-tree --write-tree HEAD "$remote/$base")
        if ($script:GitExit -eq 1) {
            Warn "WARNING: The MR will have MERGE CONFLICTS with $base!"
            Hint "Recommended: resolve conflicts locally before pushing:  git rebase $remote/$base"
            if (-not $script:NonInteractive -and -not $script:Force) {
                if (-not (Confirm-Action "Push anyway even though it has merge conflicts with '$base'?" 'n' $false)) {
                    Die $EX_STATE "Stopped so you can resolve conflicts with '$remote/$base' first." @("Run: git rebase $remote/$base", 'Resolve conflicts -> git add <files> -> git rebase --continue', 'Then run .\git_flow.bat again to push.')
                }
            }
        } else {
            Ok "No conflicts detected with $remote/$base."
            $dirtyNow = Git-Out status --porcelain --untracked-files=no
            if (-not $script:NonInteractive -and -not $dirtyNow) {
                $alreadyPushed = Git-Ok show-ref --verify --quiet "refs/remotes/$remote/$cur"
                $method = if ($alreadyPushed) { "merge $remote/$base (safe, no force-push needed)" } else { "rebase onto $remote/$base (clean linear history)" }
                if (Confirm-Action "Update your branch with latest '$remote/$base' automatically before pushing ($method)?" 'y' $false) {
                    if ($alreadyPushed) {
                        if ((Try-Git @('merge', '--no-edit', "$remote/$base")) -ne 0) {
                            [void](Try-Git @('merge', '--abort'))
                            Warn 'Auto-merge could not complete cleanly and was safely aborted. Continuing with push.'
                        } else { Ok "Branch updated with latest '$remote/$base'." }
                    } else {
                        if ((Try-Git @('rebase', "$remote/$base")) -ne 0) {
                            [void](Try-Git @('rebase', '--abort'))
                            Warn 'Auto-rebase could not complete cleanly and was safely aborted. Continuing with push.'
                        } else { Ok "Branch rebased cleanly onto latest '$remote/$base'." }
                    }
                }
            }
        }
    }

    Read-MrPeople
    Build-MrMetadata
    Find-MrTool
    $pushArgs = @('push', '--set-upstream', $remote, $cur)
    $useGitLabPushOpts = $false
    $remoteUrl = Git-Out remote get-url $remote
    if ($script:DoMr -and -not $script:MrTool -and $remoteUrl -notmatch 'github\.com') {
        $useGitLabPushOpts = $true
        $escapedDesc = ($script:MrBody -replace "`r`n", '\n' -replace "`n", '\n')
        $pushArgs += @('-o', 'merge_request.create', '-o', "merge_request.target=$base", '-o', "merge_request.title=$($script:MrTitle)", '-o', "merge_request.description=$escapedDesc", '-o', 'merge_request.remove_source_branch')
        if ($script:Assignee) {
            $aClean = ($script:Assignee -split '[\s,]+' | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ } | Select-Object -First 1)
            if ($aClean) { $pushArgs += @('-o', "merge_request.assign=$aClean") }
        }
        if ($script:Draft) { $pushArgs += @('-o', 'merge_request.draft') }
        Info "Pushing '$cur' to '$remote' (git push --set-upstream $remote $cur) with GitLab auto-MR push options (title, description, assignee/reviewer, delete after merge)..."
    } else {
        Info "Pushing '$cur' to '$remote' (git push --set-upstream $remote $cur)..."
    }
    $rc = Try-Git $pushArgs
    if ($rc -ne 0 -and $useGitLabPushOpts -and $script:LastLog -match 'push options|not support') {
        Warn 'Remote server does not support GitLab push options; retrying normal git push...'
        $useGitLabPushOpts = $false
        $rc = Try-Git @('push', '--set-upstream', $remote, $cur)
    }
    if ($rc -eq 0) {
        Ok "Pushed $cur -> $remote (upstream tracking set)."
        if ($useGitLabPushOpts) {
            $script:MrCreatedViaPush = $true
            Ok "GitLab Merge Request created via push options ($cur -> $base, delete source branch enabled)."
        }
        $m = [regex]::Match($script:LastLog, 'https?://\S*(merge_requests|pull)\S*')
        if ($m.Success) {
            $url = $m.Value.Trim()
            # If GitLab returned a GUI creation URL (/merge_requests/new), pre-fill target branch, title & delete-after-merge checkbox!
            if ($url -match '/merge_requests/new') {
                $sep = if ($url -match '\?') { '&' } else { '?' }
                $encBase = [System.Uri]::EscapeDataString($base)
                $encTitle = [System.Uri]::EscapeDataString($script:MrTitle)
                $url = "${url}${sep}merge_request%5Btarget_branch%5D=${encBase}&merge_request%5Btitle%5D=${encTitle}&merge_request%5Bforce_remove_source_branch%5D=1"
            }
            $script:PushUrl = $url
        }
    } else {
        Fail-Push
    }
}

function Open-InEdge([string]$Url) {
    $edgePaths = @('msedge')
    if (${env:ProgramFiles(x86)}) { $edgePaths += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles) { $edgePaths += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    foreach ($p in $edgePaths) {
        if ($p -eq 'msedge') {
            if (Get-Command msedge -ErrorAction SilentlyContinue) {
                Start-Process 'msedge' -ArgumentList $Url
                return $true
            }
        } elseif (Test-Path -LiteralPath $p) {
            Start-Process $p -ArgumentList $Url
            return $true
        }
    }
    try { Start-Process "microsoft-edge:$Url"; return $true } catch { }
    try { Start-Process $Url; return $true } catch { return $false }
}

function Show-MrHandoff {
    Step 'MR hand-off'
    Read-MrPeople
    Build-MrMetadata
    if (-not $script:DryRun) {
        [System.IO.File]::WriteAllText($script:MrBodyFile, $script:MrBody + "`n", (New-Object System.Text.UTF8Encoding $false))
        Info "Description saved to: $($script:MrBodyFile)"
        if (-not [Console]::IsOutputRedirected) {
            try { Set-Clipboard -Value $script:MrBody -ErrorAction Stop; Ok 'Description copied to clipboard (press Ctrl+V in GitLab).' } catch { }
        }
    }
    Write-Host ''; Write-Line '---- MR TITLE ----' 'White'; Write-Host $script:MrTitle
    Write-Host ''; Write-Line '---- MR DESCRIPTION ----' 'White'; Write-Host $script:MrBody; Write-Line '---- END ----' 'White'
    if ($script:PushUrl) {
        Info "GitLab MR Link: $($script:PushUrl)"
        if (-not $script:NonInteractive -and -not $script:DryRun) {
            if ($script:MrMode -eq 'gui') {
                Info 'Opening GitLab MR link in Microsoft Edge...'
                if (-not (Open-InEdge $script:PushUrl)) { Warn 'Could not launch Microsoft Edge automatically - copy the URL above.' }
            } elseif ($script:MrMode -ne 'none') {
                if (Confirm-Action 'Open the GitLab MR link in Microsoft Edge now?' 'y' $false) {
                    if (-not (Open-InEdge $script:PushUrl)) { Warn 'Could not launch Microsoft Edge automatically - copy the URL above.' }
                }
            }
        }
    }
}

function Find-MrTool {
    $script:MrTool = ''
    $url = Git-Out remote get-url $script:Remote
    $hasGlab = [bool](Get-Command glab -ErrorAction SilentlyContinue)
    $hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
    if ($url -match 'gitlab') { if ($hasGlab) { $script:MrTool = 'glab' } }
    elseif ($url -match 'github') { if ($hasGh) { $script:MrTool = 'gh' } }
    else { if ($hasGlab) { $script:MrTool = 'glab' } elseif ($hasGh) { $script:MrTool = 'gh' } }
}

function New-MergeRequest {
    if ($script:MrCreatedViaPush) { return $true }
    Find-MrTool
    if (-not $script:MrTool) {
        Warn 'No CLI tool (glab/gh) found and push-options MR was not used - use the printed MR link/text above.'
        $u = if ($script:PushUrl) { " and open: $($script:PushUrl)" } else { '' }
        Hint "Use the title/description printed above$u"
        return $false
    }
    Step "Creating MR with $($script:MrTool)"
    if ($script:DryRun) {
        $sub = if ($script:MrTool -eq 'glab') { 'mr' } else { 'pr' }
        Write-Line "  [dry-run] would run: $($script:MrTool) $sub create ... (title/description as printed above)" 'Yellow'
        return $true
    }
    if ($script:MrTool -eq 'glab') {
        $a = @('mr', 'create', '--source-branch', $script:CurBranch, '--target-branch', $script:BaseBranch,
            '--title', (Convert-NativeArg $script:MrTitle), '--description', (Convert-NativeArg $script:MrBody), '--remove-source-branch', '--yes')
        if ($script:Assignee) {
            $aClean = ($script:Assignee -split '[\s,]+' | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ } | Select-Object -First 1)
            if ($aClean) { $a += @('--assignee', $aClean) }
        }
        if ($script:Reviewer) {
            $rList = @($script:Reviewer -split '[\s,]+' | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ })
            if ($rList.Count -gt 0) { $a += @('--reviewer', ($rList -join ',')) }
        }
    } else {
        $a = @('pr', 'create', '--head', $script:CurBranch, '--base', $script:BaseBranch,
            '--title', (Convert-NativeArg $script:MrTitle), '--body-file', $script:MrBodyFile)
    }
    if ($script:Draft) { $a += '--draft' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $script:MrTool @a 2>&1 | ForEach-Object { Write-Host "$_" } } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -eq 0) { Ok 'MR created.'; return $true }
    Warn "$($script:MrTool) could not create the MR (already exists? not authenticated?)."
    Hint "Check: $($script:MrTool) auth status   -   or paste the description printed above into the web UI"
    return $false
}

function Invoke-CommitPush {
    Confirm-WorkBranch
    Test-BranchConvention
    Resolve-CommitJira
    if ($script:DoCommit) { Invoke-StageAndCommit }
    if ($script:DoPush) {
        Confirm-BaseRef
        Invoke-Push
        Show-MrHandoff
        if ($script:DoMr) {
            if (-not (New-MergeRequest)) { $script:MrFailed = $true }
        } else {
            Hint "Tip: add --mr next time to auto-create the GitLab MR during push."
        }
    } else {
        Ok "Done. Push when ready:  $($script:Self) --push --mr"
    }
}

function Invoke-MrText {
    if ($script:Detached -or (Test-Protected $script:CurBranch)) {
        $where = if ($script:CurBranch) { $script:CurBranch } else { 'detached HEAD' }
        Die $EX_PROTECTED "'$where' is not a work branch - no MR text to generate." @('Switch to your feature branch first.')
    }
    Confirm-BaseRef
    Show-MrHandoff
}

function Invoke-UndoCommit {
    Step 'Undo Last Unpushed Commit'
    if ($script:Detached -or (Test-Protected $script:CurBranch)) {
        $where = if ($script:CurBranch) { $script:CurBranch } else { 'detached HEAD' }
        Die $EX_PROTECTED "Refusing to undo commit on '$where' (protected / detached)." @('Switch to your feature branch first.')
    }
    $remote = $script:Remote; $cur = $script:CurBranch; $base = $script:BaseBranch
    $unpushed = 0
    if (Git-Ok show-ref --verify --quiet "refs/remotes/$remote/$cur") {
        $unpushed = [int](Git-Out rev-list --count "$remote/$cur..HEAD" --)
    } else {
        Confirm-BaseRef
        $unpushed = [int](Git-Out rev-list --count "$remote/$base..HEAD" --)
    }
    if ($unpushed -le 0) {
        Die $EX_STATE "No unpushed local commits to undo on '$cur'." @('Only commits that have NOT been pushed to GitLab yet can be safely undone here.')
    }
    $lastCommit = Git-Out log -1 --oneline
    Info "Last unpushed commit: $lastCommit"
    Info "This runs 'git reset --soft HEAD~1': all your file edits stay intact and staged."
    if (-not (Confirm-Action "Undo this commit (keeping all your code changes)?" 'n' $false)) {
        Info 'Cancelled - commit was not undone.'
        return
    }
    Run-Git @('reset', '--soft', 'HEAD~1')
    Ok 'Last commit undone. Your file changes are still intact and staged (run git status to inspect).'
}

function Invoke-UpdateFromBase {
    Step "Update Branch with Latest '$($script:Remote)/$($script:BaseBranch)'"
    if ($script:Detached -or (Test-Protected $script:CurBranch)) {
        $where = if ($script:CurBranch) { $script:CurBranch } else { 'detached HEAD' }
        Die $EX_PROTECTED "Not on a work branch ('$where')." @('Switch to your feature branch first, or use --sync to update develop.')
    }
    Confirm-BaseRef
    $remote = $script:Remote; $cur = $script:CurBranch; $base = $script:BaseBranch
    $dirty = Git-Out status --porcelain --untracked-files=no
    if ($dirty) {
        Die $EX_STATE 'You have uncommitted changes to tracked files.' @('Commit or stash them first (git stash push -m wip) before updating from develop.')
    }
    $behindBase = [int](Git-Out rev-list --count "HEAD..$remote/$base" --)
    if ($behindBase -eq 0) {
        Ok "Branch '$cur' is already up to date with '$remote/$base'."
        return
    }
    Info "Branch '$cur' is $behindBase commit(s) behind '$remote/$base'. Checking for merge conflicts..."
    [void](Git-Cap merge-tree --write-tree HEAD "$remote/$base")
    if ($script:GitExit -eq 1) {
        Warn "Merge CONFLICTS detected between '$cur' and '$remote/$base'!"
        Hint "Resolve conflicts manually so you can review each line:"
        Hint "  git rebase $remote/$base"
        Hint "  (fix files -> git add <files> -> git rebase --continue, or git rebase --abort)"
        return
    }
    Ok "Zero conflicts detected with '$remote/$base'!"
    $alreadyPushed = Git-Ok show-ref --verify --quiet "refs/remotes/$remote/$cur"
    if ($alreadyPushed) {
        Info "Branch is already pushed to '$remote' - using safe merge (no force-push needed)..."
        if ((Try-Git @('merge', '--no-edit', "$remote/$base")) -ne 0) {
            [void](Try-Git @('merge', '--abort'))
            Die $EX_GIT "Merge could not complete cleanly and was safely aborted."
        }
        Ok "Branch '$cur' updated with latest '$remote/$base' via merge. Ready to push!"
    } else {
        Info "Branch has not been pushed yet - rebasing cleanly onto '$remote/$base'..."
        if ((Try-Git @('rebase', "$remote/$base")) -ne 0) {
            [void](Try-Git @('rebase', '--abort'))
            Die $EX_GIT "Rebase could not complete cleanly and was safely aborted."
        }
        Ok "Branch '$cur' rebased cleanly onto latest '$remote/$base'. Ready to push!"
    }
}

function Invoke-MultiBranch([string]$Root, [string[]]$Repos) {
    Step "Multi-Component Branch Creation ($($Repos.Count) repositories)"
    foreach ($r in $Repos) { Info ("  Target: " + (Get-RepoRelativeLabel $Root $r)) }
    Write-Host ''
    Read-BranchInputs
    $targetBranch = $script:BranchName
    $origJira = $script:JiraId; $origType = $script:BranchType; $origDesc = $script:Desc

    Invoke-DotRepoFetch $Root
    $created = 0; $existing = 0; $failed = 0
    foreach ($r in $Repos) {
        $label = Get-RepoRelativeLabel $Root $r
        Write-Host ''
        Write-Line "=== [$label] ===" 'Cyan'
        try {
            Set-Location -LiteralPath $r
            $script:RepoDir = $r
            $script:JiraId = $origJira; $script:BranchType = $origType; $script:Desc = $origDesc; $script:BranchName = $targetBranch
            Initialize-GitEnv
            if (-not (Git-Ok rev-parse --is-inside-work-tree)) { Warn "Skipping '$label' (not a valid working tree)."; $failed++; continue }
            Test-RepoState
            [void](Git-Out symbolic-ref -q HEAD)
            if ($script:GitExit -eq 0) { $script:Detached = $false; $script:CurBranch = Git-Out symbolic-ref --short HEAD }
            else { $script:Detached = $true; $script:CurBranch = '' }
            Resolve-RemoteName
            if (-not $script:NoFetch) {
                Info "Running 'git fetch --all --prune'..."
                $fo = Git-Cap fetch --all --prune --quiet
                if ($script:GitExit -ne 0) { Warn "Fetch failed in '$label'."; $failed++; continue }
                Resolve-RemoteName
            }
            Confirm-BaseRef
            if (-not (Test-BranchFree)) {
                Ok "[$label] Switched to existing branch '$targetBranch'."
                $existing++; continue
            }
            if ($script:Detached) { Protect-DetachedHead }
            Protect-DirtyTree
            if ($script:CarryChanges) {
                Run-Git @('checkout', '-b', $targetBranch)
                Ok "[$label] Created branch '$targetBranch' (carried uncommitted changes safely)."
            } else {
                $syncedLocal = Sync-LocalBaseBranch
                if ($syncedLocal) { Run-Git @('checkout', '-b', $targetBranch) }
                else { Run-Git @('checkout', '-b', $targetBranch, '--no-track', "$($script:Remote)/$($script:BaseBranch)") }
                Ok "[$label] Created branch '$targetBranch' off latest '$($script:BaseBranch)'."
            }
            $created++
        } catch {
            Warn "[$label] Failed: $($_.Exception.Message)"
            $failed++
        }
    }
    Step 'Multi-Component Branch Summary'
    Ok "Created '$targetBranch': $created   |   Switched to existing: $existing   |   Failed: $failed"
}

function Invoke-DiscardFiles {
    Step 'Safely Discard Unwanted File Changes (with Stash Backup)'
    $raw = Git-Out -c core.quotepath=off status --porcelain
    $lines = @($raw -split "`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) {
        Ok 'Working tree is already clean - nothing to discard.'
        return
    }
    $items = @()
    foreach ($ln in $lines) {
        if ($ln.Length -lt 4) { continue }
        $st = $ln.Substring(0, 2)
        $path = $ln.Substring(3).Trim()
        if ($path -match ' -> (.+)$') { $path = $Matches[1] }
        $path = $path.Trim('"')
        $kind = if ($st -eq '??') { 'untracked' } else { 'modified' }
        $items += [PSCustomObject]@{ Status = $st; Path = $path; Kind = $kind }
    }
    if ($items.Count -eq 0) { Ok 'Working tree is clean - nothing to discard.'; return }

    Info 'Files with uncommitted changes in this component:'
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        Write-Host ("  [{0}]  {1}  {2}  ({3})" -f ($i + 1), $it.Status, $it.Path, $it.Kind)
    }

    $chosen = @()
    if ($script:NonInteractive) {
        Die $EX_USAGE 'Cannot pick files to discard in non-interactive mode.' @('Run interactively to select which files to discard safely.')
    }
    Write-Host ''
    while ($true) {
        $sel = Read-Host "Enter file numbers to discard (e.g. 1 3, 'a' = all, 'q' = cancel)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        $sel = $sel.Trim()
        if ($sel -match '^[qQ]$') { Info 'Cancelled - no files were touched.'; return }
        if ($sel -match '^[aA]$') { $chosen = @($items | ForEach-Object { $_.Path }); break }
        $tokens = @($sel -split '[\s,]+' | Where-Object { $_ })
        $tmpList = New-Object System.Collections.Generic.List[string]
        $valid = $true
        foreach ($t in $tokens) {
            $n = 0
            if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
                $p = $items[$n - 1].Path
                if (-not $tmpList.Contains($p)) { $tmpList.Add($p) }
            } else {
                $valid = $false; break
            }
        }
        if ($valid -and $tmpList.Count -gt 0) { $chosen = @($tmpList.ToArray()); break }
        Warn "Please enter numbers between 1 and $($items.Count) (e.g. 1 2), 'a' for all, or 'q' to cancel."
    }

    Write-Host ''
    Warn "About to discard changes in $($chosen.Count) file(s):"
    foreach ($p in $chosen) { Write-Host "       $p" }
    Info 'A safety backup will be saved in git stash BEFORE discarding so you can restore anytime.'
    if (-not (Confirm-Action "Discard these $($chosen.Count) file(s) now?" 'n' $false)) {
        Info 'Cancelled - no files were touched.'
        return
    }

    $backupMsg = "git_flow backup before discard $(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $stashArgs = @('stash', 'push', '--include-untracked', '-m', $backupMsg, '--') + $chosen
    Run-Git $stashArgs
    Ok "Discarded changes in $($chosen.Count) file(s)."
    Info "Safety backup saved in git stash: `"$backupMsg`""
    Hint 'Changed your mind? Restore with: git stash pop   (or inspect: git stash list)'
}

function Select-MrModeInteractive {
    Write-Host ''
    Write-Host 'How would you like to raise the Merge Request on GitLab?'
    Write-Host '  [1] GitLab GUI (open MR page in Microsoft Edge so you can review/add notes & click Create)'
    Write-Host '  [2] Auto-create from CLI (create MR automatically during push with Assignee/Reviewer CDS ID)'
    Write-Host '  [3] Push only (skip raising MR for now)'
    $mc = Read-Value 'Enter choice' '1'
    switch ($mc.ToLowerInvariant()) {
        { $_ -in @('1', 'gui', 'edge', 'browser') } { $script:MrMode = 'gui'; $script:DoMr = $false }
        { $_ -in @('2', 'cli', 'auto') } { $script:MrMode = 'cli'; $script:DoMr = $true }
        { $_ -in @('3', 'none', 'push', 'skip') } { $script:MrMode = 'none'; $script:DoMr = $false }
        default { Warn "Unrecognised choice; using GitLab GUI (Microsoft Edge)."; $script:MrMode = 'gui'; $script:DoMr = $false }
    }
}

function Invoke-Wizard {
    Step 'Complete Workflow Wizard (Branch -> Commit -> Push -> MR)'
    # 1. Branch creation (if not already on a Jira branch, or if user wants a new one)
    $needBranch = $true
    if (-not $script:Detached -and -not (Test-Protected $script:CurBranch) -and ($script:CurBranch -cmatch $script:BranchRegex) -and -not $script:Desc) {
        if ($script:NonInteractive) {
            $needBranch = $false
            Info "Already on Jira branch '$($script:CurBranch)' - keeping it."
        } elseif (Confirm-Action "Already on Jira branch '$($script:CurBranch)'. Continue on this branch?" 'y' $true) {
            $needBranch = $false
        }
    }
    if ($needBranch) {
        Invoke-Branch
        $script:CurBranch = $script:BranchName
        $script:Detached = $false
    }

    # 2. Commit (if uncommitted changes exist)
    $pending = Git-Out status --porcelain
    if ($pending) {
        Resolve-CommitJira
        Invoke-StageAndCommit
    } elseif (Test-UnpushedCommits) {
        Resolve-CommitJira
        Info 'Working tree is clean - will proceed with existing unpushed commit(s).'
    } else {
        Ok "Branch '$($script:CurBranch)' is ready. Edit your files, then run .\git_flow.bat --wizard again to commit, push & raise MR."
        return
    }

    # 3. Push + MR
    $wantPush = if ($script:DoPush -or $script:DoMr) { $true } else { Confirm-Action "Push '$($script:CurBranch)' to '$($script:Remote)' now?" 'y' $true }
    if (-not $wantPush) {
        Ok "Committed locally on '$($script:CurBranch)'. Run .\git_flow.bat --push --mr when ready."
        return
    }
    $script:DoPush = $true
    if (-not $script:DoMr -and -not $script:NonInteractive) {
        Select-MrModeInteractive
    }
    Confirm-BaseRef
    Invoke-Push
    Show-MrHandoff
    if ($script:DoMr) {
        if (-not (New-MergeRequest)) { $script:MrFailed = $true }
    }
}

function Show-Menu {
    Step 'Choose an action'
    Write-Host '  [0] Wizard: Full Flow (Branch + Commit + Push + MR in one go)'
    Write-Host "  [1] Start New Branch (fetch --all -> checkout & pull $($script:BaseBranch) -> create Jira branch)"
    Write-Host '  [2] Commit changes (+ Push & Raise GitLab MR)'
    Write-Host '  [3] Push existing commits (+ Raise GitLab MR)'
    Write-Host '  [4] Show MR title/description for this branch'
    Write-Host "  [5] Sync ALL workspace repos (fetch --all -> checkout $($script:BaseBranch) -> pull)"
    Write-Host '  [6] Undo last unpushed commit (keeps all your file changes intact)'
    Write-Host "  [7] Update current branch with latest $($script:BaseBranch) (conflict-checked)"
    Write-Host '  [8] Discard unwanted file changes (saves a safety stash backup first)'
    Write-Host '  [q] Quit'
    $c = Read-Host 'Enter choice'
    switch ($c) {
        '0' { $script:DoWizard = $true }
        '1' { $script:DoBranch = $true }
        '2' { $script:DoCommit = $true; if (Confirm-Action "Push to '$($script:Remote)' after committing?" 'y' $true) { $script:DoPush = $true } }
        '3' { $script:DoPush = $true }
        '4' { $script:DoMrText = $true }
        '5' { $script:DoSync = $true }
        '6' { $script:DoUndo = $true }
        '7' { $script:DoUpdate = $true }
        '8' { $script:DoDiscard = $true }
        { $_ -in @('q', 'Q') } { Info 'Bye.'; throw 'GITFLOW_QUIT' }
        default { Die $EX_USAGE "Invalid choice '$c'." }
    }
    if ($script:DoPush) {
        Select-MrModeInteractive
    }
}

function Reset-InteractiveRunState {
    $script:DoBranch = $false; $script:DoCommit = $false; $script:DoPush = $false
    $script:DoMr = $false; $script:DoMrText = $false; $script:DoSync = $false
    $script:DoWizard = $false; $script:DoUndo = $false; $script:DoUpdate = $false; $script:DoDiscard = $false
    $script:Component = ''; $script:JiraId = ''; $script:BranchType = ''; $script:Desc = ''; $script:CommitMsg = ''
    $script:Assignee = ''; $script:Reviewer = ''; $script:MrPeoplePrompted = $false
    $script:RepoDir = ''; $script:MultiRepos = @(); $script:CurBranch = ''; $script:Detached = $false
    $script:BranchName = ''; $script:Sanitized = ''; $script:SimCommit = $false; $script:CarryChanges = $false
    $script:HasStaged = $false; $script:FormattedMsg = ''; $script:PushUrl = ''
    $script:MrTitle = ''; $script:MrBody = ''; $script:MrCreatedViaPush = $false; $script:MrMode = ''
}

# ------------------------------------------------------------------ main -----
function Invoke-Main([object[]]$Argv) {
    $startDir = (Get-Location).ProviderPath
    $script:WorkspaceRoot = $startDir
    Parse-Args $Argv
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die $EX_STATE 'git is not installed or not on PATH.' }
    Determine-Mode

    Write-Line '=========================================' 'Cyan'
    Write-Line " Git & Jira Flow Assistant  v$($script:VERSION)" 'White'
    Write-Line '=========================================' 'Cyan'

    if ($script:DoHealth) {
        $all = @(Find-Repos $startDir)
        if ($all.Count -eq 0) { Die $EX_NOTFOUND "No git repositories found under $startDir." }
        Show-WorkspaceHealth $startDir $all
        return 0
    }

    if ($script:DoStatus) {
        $all = @(Find-Repos $startDir)
        if ($all.Count -eq 0) { Die $EX_NOTFOUND "No git repositories found under $startDir." }
        [void](Show-WorkspaceDashboard $startDir $all)
        return 0
    }

    if ($script:DryRun) { Warn 'DRY RUN: mutating commands are only printed, never executed.' }

    while ($true) {
        Set-Location -LiteralPath $startDir
        if ($script:DoSync -and -not $script:Component) {
            Initialize-GitEnv
            Invoke-SyncAll $startDir
        } else {
            Resolve-Repo
            if ($script:MultiRepos.Count -gt 1) {
                Initialize-GitEnv
                Invoke-MultiBranch $startDir $script:MultiRepos
            }
            elseif ($script:DoSync -and -not $script:Component) {
                Initialize-GitEnv
                Invoke-SyncAll $startDir
            } else {
                Set-Location -LiteralPath $script:RepoDir
                $script:RepoDir = (Get-Location).ProviderPath
                Ok "Working in: $($script:RepoDir)"
                Initialize-GitEnv
                Invoke-Preflight
                Show-Status

                if ($script:MenuMode) { Show-Menu }

                if ($script:DoSync) {
                    if ($script:Component) {
                        Confirm-BaseRef
                        [void](Sync-LocalBaseBranch)
                    } else {
                        Invoke-SyncAll $startDir
                    }
                }
                elseif ($script:DoWizard) { Invoke-Wizard }
                elseif ($script:DoUndo) { Invoke-UndoCommit }
                elseif ($script:DoUpdate) { Invoke-UpdateFromBase }
                elseif ($script:DoDiscard) { Invoke-DiscardFiles }
                elseif ($script:DoBranch) { Invoke-Branch }
                elseif ($script:DoMrText) { Invoke-MrText }
                else { Invoke-CommitPush }
            }
        }

        if ($script:DryRun) { Write-Host ''; Write-Line 'Dry run complete - nothing was changed.' 'Yellow' }
        if (-not $script:MenuMode -or $script:NonInteractive) { break }
        Write-Host ''
        if (-not (Confirm-Action 'Work on another component / perform another action in this workspace?' 'n' $false)) { break }
        Reset-InteractiveRunState
    }

    if ($script:MrFailed) { return $EX_MR }
    return 0
}

$exitCode = 0
$origDir = (Get-Location).ProviderPath
try {
    $exitCode = [int](Invoke-Main $args)
} catch {
    $ex = $_.Exception
    if ($ex.Message -eq 'GITFLOW_QUIT') { $exitCode = 0 }
    elseif ($ex.Data -and $ex.Data.Contains('Code')) {
        Write-Line "[ERR] $($ex.Message)" 'Red'
        foreach ($h in $ex.Data['Hints']) { if ($h) { Hint $h } }
        $exitCode = [int]$ex.Data['Code']
    } else {
        Write-Line "[ERR] Unexpected failure: $($ex.Message)" 'Red'
        if ($_.InvocationInfo) { Hint ("at " + $_.InvocationInfo.PositionMessage.Replace("`n", ' ')) }
        Hint "Preview safely with --dry-run, or report this message to the tooling team."
        $exitCode = 1
    }
    if ($exitCode -ne 0) { Write-Line 'Nothing was force-pushed or deleted. Re-run with --dry-run to preview.' 'DarkGray' }
} finally {
    Set-Location -LiteralPath $origDir
    foreach ($f in $script:TempFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if ($script:StashCreated) {
        Write-Host ''
        Write-Line "[!!] Your uncommitted changes are safe in a stash: `"$($script:StashMsg)`"" 'Yellow'
        Hint 'Inspect: git stash list   |   Restore: git stash pop'
    }
}
exit $exitCode
