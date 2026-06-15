# setup.ps1 — Bootstrap the full GitLab + RelayProxy + Jenkins POC
# Run from the project root after: docker-compose up -d

param(
    [string]$GitLabUrl    = "http://localhost:8929",
    [string]$JenkinsUrl   = "http://localhost:8080",
    [string]$RelayUrl     = "http://localhost:3000",
    [string]$GitLabPass   = "Admin1234!",
    [string]$WebhookSecret = "webhook-secret-123",
    [string]$ProjectName  = "my-python-app"
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Red }

# ── Step 1: Wait for GitLab ──────────────────────────────────────────────────
Write-Step "Waiting for GitLab to become healthy (may take 5-10 minutes on first boot)..."
$maxWait = 600   # seconds — GitLab CE first boot can take 7-10 min
$elapsed = 0
$gitlabReady = $false
while ($elapsed -lt $maxWait) {
    try {
        # Use /users/sign_in — more reliable than /-/health which can return
        # non-200 even when the UI is already serving traffic
        $r = Invoke-WebRequest -Uri "$GitLabUrl/users/sign_in" -TimeoutSec 10 `
            -UseBasicParsing -MaximumRedirection 5
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
            Write-OK "GitLab is up (HTTP $($r.StatusCode))"
            $gitlabReady = $true
            break
        }
    } catch { }
    Write-Host "    Waiting... ($elapsed s elapsed, max $maxWait s)" -ForegroundColor Gray
    Start-Sleep -Seconds 15
    $elapsed += 15
}
if (-not $gitlabReady) { Write-Fail "GitLab did not start in time. Check: docker logs gitlab"; exit 1 }

# ── Step 2: Create a GitLab Personal Access Token via Rails runner ───────────
Write-Step "Creating GitLab Personal Access Token for root..."

# Write the Ruby script to a local temp file — avoids all PowerShell/shell quoting issues
$tempRb = Join-Path $env:TEMP "create_pat.rb"
Set-Content -Path $tempRb -Encoding UTF8 -Value @'
token = User.find_by_username('root').personal_access_tokens.create(
  scopes: ['api', 'read_repository', 'write_repository'],
  name: 'setup-token',
  expires_at: 365.days.from_now
)
puts token.token
'@

docker cp $tempRb gitlab:/tmp/create_pat.rb | Out-Null
Remove-Item $tempRb -ErrorAction SilentlyContinue

# Temporarily allow non-terminating errors so rails runner warnings don't abort
$prevPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$railsOutput = docker exec gitlab gitlab-rails runner /tmp/create_pat.rb 2>&1
$ErrorActionPreference = $prevPref

# Extract the token — rails runner may emit warnings before the actual token line
$PAT = ($railsOutput |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -match '^glpat-' } |
    Select-Object -Last 1)

# Fallback: grab last non-empty line if token prefix not found
if (-not $PAT) {
    $PAT = ($railsOutput |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^\S{15,}$' } |
        Select-Object -Last 1)
}

if (-not $PAT -or $PAT.Length -lt 10) {
    Write-Fail "Could not create PAT. Rails output: $railsOutput"
    Write-Fail "Try manually: GitLab > Profile > Access Tokens > Add new token"
    exit 1
}
Write-OK "Personal Access Token created"

# ── Step 3: Create the GitLab project ────────────────────────────────────────
Write-Step "Creating GitLab project: $ProjectName..."
$headers = @{ "Private-Token" = $PAT; "Content-Type" = "application/json" }
$body    = @{ name = $ProjectName; visibility = "public"; initialize_with_readme = $false } | ConvertTo-Json

try {
    $project = Invoke-RestMethod -Method POST -Uri "$GitLabUrl/api/v4/projects" `
        -Headers $headers -Body $body
    Write-OK "Project created: $($project.http_url_to_repo)"
} catch {
    # Project may already exist
    $project = Invoke-RestMethod -Method GET -Uri "$GitLabUrl/api/v4/projects/root%2F$ProjectName" -Headers $headers
    Write-OK "Project already exists: $($project.http_url_to_repo)"
}
$projectId = $project.id

# ── Step 4: Configure the GitLab webhook ─────────────────────────────────────
Write-Step "Adding webhook to GitLab project (pointing to RelayProxy)..."
# Webhook target: relay-proxy on Docker internal network
$webhookBody = @{
    url                    = "http://relay-proxy:3000/webhook"
    token                  = $WebhookSecret
    push_events            = $true
    merge_requests_events  = $false
    tag_push_events        = $false
    enable_ssl_verification = $false
} | ConvertTo-Json

try {
    Invoke-RestMethod -Method POST `
        -Uri "$GitLabUrl/api/v4/projects/$projectId/hooks" `
        -Headers $headers -Body $webhookBody | Out-Null
    Write-OK "Webhook configured: http://relay-proxy:3000/webhook"
} catch {
    Write-Host "    Webhook may already exist or failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ── Step 5: Push sample-python-app to GitLab ─────────────────────────────────
Write-Step "Pushing sample-python-app to GitLab..."
$repoPath = Join-Path $PSScriptRoot "sample-python-app"
$remoteUrl = "http://root:$([Uri]::EscapeDataString($GitLabPass))@localhost:8929/root/$ProjectName.git"

Push-Location $repoPath
try {
    if (-not (Test-Path ".git")) {
        git init
        git checkout -b main
    }
    git add .
    git -c "user.email=devops@demo.local" -c "user.name=DevOps" commit -m "Initial commit: sample Python app" 2>&1 | Out-Null
    git remote remove origin 2>$null
    git remote add origin $remoteUrl
    git push -u origin main --force
    Write-OK "Code pushed to GitLab"
} catch {
    Write-Fail "Git push failed: $($_.Exception.Message)"
} finally {
    Pop-Location
}

# ── Step 6: Wait for Jenkins ──────────────────────────────────────────────────
Write-Step "Waiting for Jenkins to become healthy..."
$elapsed = 0
while ($elapsed -lt 180) {
    try {
        $r = Invoke-WebRequest -Uri "$JenkinsUrl/login" -TimeoutSec 5 -UseBasicParsing
        if ($r.StatusCode -eq 200) { Write-OK "Jenkins is up"; break }
    } catch { }
    Write-Host "    Waiting... ($elapsed s)" -ForegroundColor Gray
    Start-Sleep -Seconds 10
    $elapsed += 10
}

# ── Step 7: Summary ───────────────────────────────────────────────────────────
Write-Host ("")
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host "  SETUP COMPLETE" -ForegroundColor Green
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host "  GitLab    : $GitLabUrl          (root / Admin1234!)"
Write-Host "  Jenkins   : $JenkinsUrl         (admin / admin123)"
Write-Host "  RelayProxy: $RelayUrl/health"
Write-Host ""
Write-Host "  To trigger the pipeline, make any commit to the GitLab repo:"
Write-Host "  cd sample-python-app"
Write-Host "  git commit --allow-empty -m 'trigger build'"
Write-Host "  git push"
Write-Host ""
Write-Host "  Watch Jenkins build: $JenkinsUrl/job/python-ci/"
Write-Host ("-" * 60) -ForegroundColor DarkGray
