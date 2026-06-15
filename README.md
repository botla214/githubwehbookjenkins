# RelayProxy POC — GitLab → Jenkins via Centralized Webhook Router

## Architecture

```
GitLab CE (port 8929)
   └── Push event → http://relay-proxy:3000/webhook  (Docker internal)
                          │
                    RelayProxy (port 3000)
                    - Validates secret token
                    - Parses repo + branch from payload
                    - Looks up routing.yaml
                    - Calls Jenkins REST API
                          │
                    Jenkins (port 8080)
                    - python-ci job (auto-configured)
                    - Clones repo from GitLab (Docker internal)
                    - Runs pytest
```

All three services run on the same Docker network (`ci-network`) — no internet tunnel required.

---

## Prerequisites

- Docker Desktop (Windows) — running
- PowerShell
- Git

---

## Quick Start

### 1. Start the stack

```powershell
docker-compose up -d --build
```

Jenkins and GitLab take a few minutes to initialize. Check status:

```powershell
docker-compose ps
docker logs -f relay-proxy
```

### 2. Run the automated setup script

```powershell
.\setup.ps1
```

This script:
- Waits for GitLab to be healthy (3-5 min)
- Creates a Personal Access Token for the root user
- Creates the `my-python-app` project in GitLab
- Configures the webhook pointing to `http://relay-proxy:3000/webhook`
- Pushes the sample Python code to GitLab
- Confirms Jenkins is ready

### 3. Trigger the pipeline

Make any change and push:

```powershell
cd sample-python-app
git commit --allow-empty -m "test: trigger RelayProxy pipeline"
git push
```

### 4. Watch it work

| What | Where |
|------|-------|
| GitLab repo | http://localhost:8929/root/my-python-app |
| RelayProxy logs | `docker logs -f relay-proxy` |
| Jenkins job | http://localhost:8080/job/python-ci/ |
| Jenkins login | admin / admin123 |
| GitLab login | root / Admin1234! |

---

## Manual Setup (if setup.ps1 fails)

### GitLab: Allow webhook to internal Docker host

1. Login to GitLab as root: http://localhost:8929
2. **Admin Area → Settings → Network → Outbound requests**
3. Check **"Allow requests to the local network from webhooks and integrations"**
4. Add `relay-proxy` to the allowlist

### Verify RelayProxy manually (without a real push)

```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:3000/webhook" `
    -Headers @{
        "X-Gitlab-Event" = "Push Hook"
        "X-Gitlab-Token" = "webhook-secret-123"
        "Content-Type"   = "application/json"
    } `
    -Body '{"ref":"refs/heads/main","repository":{"name":"my-python-app"}}'
```

Expected response:
```json
{ "success": true, "job": "python-ci", "repo": "my-python-app", "branch": "main" }
```

---

## How Routing Works

Edit `relay-proxy/config/routing.yaml` to add rules:

```yaml
routes:
  - repo: my-python-app
    branch: main
    jenkins_job: python-ci

  - repo: another-service
    branch: "*"            # wildcard matches any branch
    jenkins_job: service-pipeline
```

After changing routing config, restart only the proxy:

```powershell
docker-compose restart relay-proxy
```

---

## Tear down

```powershell
docker-compose down -v   # -v removes volumes (wipes all data)
```
