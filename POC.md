POC : The engineering of a centralized RelayProxy service to rationalize webhook management between GitLab and Jenkins.

---

## Problem Statement

The current integration between GitLab and Jenkins requires the creation and management of individual webhook addresses for each branch and repository combination. This architecture introduces considerable operational complexity and does not scale effectively as the number of repositories and pipelines grows. The resulting webhook sprawl increases maintenance overhead and introduces fragility into the CI/CD delivery pipeline.

---

## Solution

A centralized RelayProxy service governs the communication layer between GitLab and Jenkins. It accepts a single inbound webhook endpoint from GitLab, parses each payload, and dynamically routes the appropriate trigger to the corresponding Jenkins job — eliminating per-branch, per-repository webhook management.

---

## Chosen Approach: All-Local Docker Compose (No Internet Tunnel)

All three services run on the same Docker bridge network (`ci-network`). GitLab calls RelayProxy using the Docker internal hostname — no ngrok or public URL required.

```
GitLab CE (port 8929)
   └── Push event  →  http://relay-proxy:3000/webhook   [Docker internal]
                              │
                       RelayProxy (port 3000)
                       Node.js / Express
                       - Validates X-Gitlab-Token secret
                       - Extracts repo name + branch from payload
                       - Matches against routing.yaml rules
                       - Calls Jenkins REST API (with CSRF crumb + session cookie)
                              │
                       Jenkins (port 8080)
                       - python-ci job (auto-configured via JCasC)
                       - Clones repo from GitLab  [Docker internal]
                       - Runs:  pip3 install -r requirements.txt
                       - Runs:  python3 -m pytest tests/ -v
                       - Reports pass / fail
```

---

## Repository Structure

```
githubwehbookjenkins/
├── docker-compose.yml           # GitLab CE + RelayProxy + Jenkins on one network
├── setup.ps1                    # Automated bootstrap script
│
├── relay-proxy/
│   ├── Dockerfile               # Node 20 Alpine
│   ├── package.json
│   ├── server.js                # Webhook receiver + Jenkins trigger logic
│   └── config/
│       └── routing.yaml         # repo + branch  →  Jenkins job mapping
│
├── jenkins/
│   ├── Dockerfile               # Jenkins LTS + Python3 + plugins pre-installed
│   ├── plugins.txt              # JCasC, git, workflow-aggregator, job-dsl
│   └── casc.yaml                # Auto-creates: admin user, gitlab-creds, python-ci job
│
└── sample-python-app/           # Dummy Python code pushed to GitLab
    ├── main.py
    ├── requirements.txt
    ├── Jenkinsfile
    └── tests/
        └── test_main.py
```

---

## Manual Step-by-Step Workflow (Full Demo)

### Step 1 — Start the full stack

```powershell
docker-compose up -d --build
```

Wait **5–10 minutes** for GitLab CE to fully initialize on first boot. Verify GitLab is up:

```powershell
Invoke-WebRequest -Uri "http://localhost:8929/users/sign_in" -UseBasicParsing
# Expect: StatusCode 200
```

---

### Step 2 — Fix GitLab admin account (first-run issue)

GitLab CE on first boot may not create the default `root` user if volumes were previously initialized. Check what users exist:

```powershell
Set-Content -Path "$env:TEMP\list_users.rb" -Encoding UTF8 -Value 'User.all.each { |u| puts u.username + " " + u.email }'
docker cp "$env:TEMP\list_users.rb" gitlab:/tmp/list_users.rb
docker exec gitlab gitlab-rails runner /tmp/list_users.rb
```

If a non-root user is listed (e.g. `botlaram`), activate it, grant admin rights, and reset its password:

```powershell
Set-Content -Path "$env:TEMP\fix_user.rb" -Encoding UTF8 -Value @'
u = User.find_by_username('botlaram')
u.state = 'active'
u.admin = true
u.password = 'Admin1234!'
u.password_confirmation = 'Admin1234!'
u.save!
puts "State: #{u.state}, Admin: #{u.admin?}"
'@
docker cp "$env:TEMP\fix_user.rb" gitlab:/tmp/fix_user.rb
docker exec gitlab gitlab-rails runner /tmp/fix_user.rb
```

Expected output: `State: active, Admin: true`

> **Note:** Replace `botlaram` with whatever username appeared in the list command above.

Log in to GitLab at **http://localhost:8929** with `botlaram` / `Admin1234!`.

---

### Step 3 — Allow local network requests in GitLab

By default GitLab blocks webhooks that point to internal/Docker hostnames. Enable it:

1. Click the hamburger menu (top-left) → **Admin Area** (`http://localhost:8929/admin`)
2. Left sidebar → **Settings** → **Network**
3. Expand **Outbound requests**
4. Check **Allow requests to the local network from webhooks and integrations**
5. In the allowlist box add: `relay-proxy`
6. Click **Save changes**

---

### Step 4 — Create a Personal Access Token in GitLab UI

1. Avatar (top-right) → **Edit profile** → **Access Tokens**
2. Click **Add new token**
   - Name: `jenkins-token`
   - Scopes: `api`, `read_repository`, `write_repository`
3. Click **Create personal access token** — **copy the token shown** (e.g. `glpat-xxxx`)

---

### Step 5 — Create the GitLab project via UI

1. Click **+** (top nav) → **New project** → **Create blank project**
   - Project name: `my-python-app`
   - Visibility: **Public**
   - Uncheck "Initialize repository with a README"
2. Click **Create project**

---

### Step 6 — Add the webhook via GitLab UI

1. Go to your project → **Settings** → **Webhooks**
2. Click **Add new webhook**
   - URL: `http://relay-proxy:3000/webhook`
   - Secret token: `webhook-secret-123`
   - Trigger: check **Push events** only
   - SSL verification: **disable**
3. Click **Add webhook**

---

### Step 7 — Push the sample Python app to GitLab

```powershell
cd c:\POC\githubwehbookjenkins\githubwehbookjenkins\sample-python-app

git init
git checkout -b main
git add .
git -c "user.email=devops@demo.local" -c "user.name=DevOps" commit -m "Initial commit: sample Python app"
git remote add origin "http://botlaram:Admin1234%21@localhost:8929/botlaram/my-python-app.git"
git push -u origin main --force
```

> Replace `botlaram` in the URL with the actual GitLab username confirmed in Step 2.

---

### Step 8 — Verify Jenkins is ready

```powershell
Invoke-WebRequest -Uri "http://localhost:8080/login" -UseBasicParsing
# Expect: StatusCode 200
```

Log in to Jenkins at **http://localhost:8080** with `admin` / `admin123`. The `python-ci` job should appear on the dashboard (JCasC creates it automatically). If missing, wait 1–2 minutes and refresh.

---

### Step 9 — Confirm the correct GitLab repo URL for Jenkins

```powershell
docker exec gitlab gitlab-rails runner "puts Project.find_by_name('my-python-app').http_url_to_repo" 2>&1 | Select-Object -Last 2
```

Note the URL returned (e.g. `http://gitlab/botlaram/my-python-app.git`). Use it in the next step.

---

### Step 10 — Update Jenkins credentials for GitLab

The default JCasC credentials use `root` which does not exist. Update them to match the actual GitLab user:

1. **Manage Jenkins** → **Credentials** → **System** → **Global credentials**
2. Find `gitlab-creds` → click **Edit**
   - Username: `botlaram`  *(your actual GitLab username)*
   - Password: paste the PAT from Step 4 (e.g. `glpat-xxxx`)
3. Click **Save**

---

### Step 11 — Update the python-ci job repo URL

1. Go to **http://localhost:8080/job/python-ci/** → **Configure**
2. Under **Pipeline** → **SCM** → **Git** → **Repository URL**, replace with the URL from Step 9:
   ```
   http://gitlab/botlaram/my-python-app.git
   ```
3. Click **Save**

---

### Step 12 — Trigger the pipeline

**Option A — Test webhook from GitLab UI**

1. Go to your project → **Settings** → **Webhooks**
2. Find the webhook entry → click **Test** → **Push events**

**Option B — Trigger directly from Jenkins UI**

1. Go to **http://localhost:8080/job/python-ci/**
2. Click **Build Now**

**Option C — Push a real commit**

```powershell
cd c:\POC\githubwehbookjenkins\githubwehbookjenkins\sample-python-app
git commit --allow-empty -m "trigger: test relay pipeline"
git push
```

**Option D — Test RelayProxy directly (no GitLab involved)**

```powershell
$body = '{"ref":"refs/heads/main","repository":{"name":"my-python-app"}}'
$headers = @{
    "X-Gitlab-Event" = "Push Hook"
    "X-Gitlab-Token" = "webhook-secret-123"
    "Content-Type"   = "application/json"
}
Invoke-RestMethod -Method POST -Uri "http://localhost:3000/webhook" -Headers $headers -Body $body
```

Expected response: `{ "success": true, "job": "python-ci", "repo": "my-python-app", "branch": "main" }`

---

### Step 13 — Observe the full flow

| What to watch | Where |
|---|---|
| GitLab repo & webhook | http://localhost:8929/botlaram/my-python-app |
| RelayProxy routing log | `docker logs -f relay-proxy` |
| Jenkins build progress | http://localhost:8080/job/python-ci/ |

**RelayProxy success log:**
```
[INFO] Routing my-python-app:main  →  Jenkins job: python-ci
[OK] Triggered Jenkins job: python-ci
```

**Jenkins Console Output:** Click the build number → **Console Output** to see pip install and pytest results.

Credentials:
- GitLab: `botlaram` / `Admin1234!`
- Jenkins: `admin` / `admin123`

---

## Known Issues & Fixes Applied

### Fix 1 — GitLab root user missing on first boot

If volumes from a prior run persist, GitLab skips creating the `root` user. The initial_root_password file is also absent after 24 hours.

**Resolution:** Use the Rails runner to find existing users, activate them, grant admin, and reset their password (see Step 2).

### Fix 2 — GitLab blocks local network webhook URLs

GitLab CE blocks outbound requests to private/Docker-internal addresses by default.

**Resolution:** Enable **Allow requests to the local network from webhooks and integrations** in Admin Area → Settings → Network → Outbound requests (see Step 3).

### Fix 3 — Webhook returns HTTP 401 invalid token

The webhook secret in GitLab did not match the `GITLAB_WEBHOOK_SECRET` env var in RelayProxy (`webhook-secret-123`).

**Resolution:** Edit the webhook in GitLab → set Secret token to `webhook-secret-123` exactly.

### Fix 4 — Webhook returns HTTP 500 / Jenkins 403 crumb error

The RelayProxy was fetching the Jenkins CSRF crumb in one HTTP session but not forwarding the session cookie with the build request. Jenkins ties crumbs to sessions and rejects mismatched ones.

**Resolution:** Updated `relay-proxy/server.js` to capture `set-cookie` from the crumb response and pass it as the `Cookie` header on the subsequent build POST. Requires a full image rebuild (not just restart):

```powershell
docker-compose up -d --build relay-proxy
```

### Fix 5 — Jenkins git clone fails with HTTP 401

JCasC pre-configures `gitlab-creds` with username `root` and password `Admin1234!`. When the actual GitLab admin user is not `root`, authentication fails.

**Resolution:** Update `gitlab-creds` in Jenkins → Manage Jenkins → Credentials to use the actual GitLab username and a Personal Access Token (not the plain password). Also update the python-ci job repo URL namespace to match (see Steps 10–11).

---

## How to Add More Routing Rules

Edit `relay-proxy/config/routing.yaml` (first match wins):

```yaml
routes:
  - repo: my-python-app
    branch: main
    jenkins_job: python-ci

  - repo: another-service
    branch: "*"           # wildcard matches any branch
    jenkins_job: service-pipeline
```

Routing rule changes only need a restart (no rebuild) since routing.yaml is read at startup:

```powershell
docker-compose restart relay-proxy
```

---

## Tear Down

```powershell
docker-compose down -v   # -v removes all volumes (full reset)
```
