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
                       - Calls Jenkins REST API (with CSRF crumb)
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

## Step-by-Step Workflow to Run the Demo

### Step 1 — Start the full stack

```powershell
docker-compose up -d --build
```

GitLab CE takes 3–5 minutes to fully initialize on first boot.

### Step 2 — Run the automated setup

```powershell
.\setup.ps1
```

The script performs these actions automatically:
1. Polls GitLab until healthy (`/-/health`)
2. Creates a Personal Access Token for the `root` user via GitLab Rails runner
3. Creates the `my-python-app` project in GitLab (public visibility)
4. Registers the webhook: `http://relay-proxy:3000/webhook` with secret token
5. Pushes `sample-python-app/` code to GitLab as the initial commit
6. Waits for Jenkins to be ready (`/login`)

### Step 3 — Trigger the pipeline

```powershell
cd sample-python-app
git commit --allow-empty -m "trigger: test relay pipeline"
git push
```

### Step 4 — Observe the full flow

| What to watch | Where |
|---|---|
| GitLab repo & webhook | http://localhost:8929/root/my-python-app |
| RelayProxy routing log | `docker logs -f relay-proxy` |
| Jenkins build progress | http://localhost:8080/job/python-ci/ |

Credentials:
- GitLab: `root` / `Admin1234!`
- Jenkins: `admin` / `admin123`

### Step 5 — Verify RelayProxy manually (without a git push)

```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:3000/webhook" `
    -Headers @{
        "X-Gitlab-Event" = "Push Hook"
        "X-Gitlab-Token" = "webhook-secret-123"
        "Content-Type"   = "application/json"
    } `
    -Body '{"ref":"refs/heads/main","repository":{"name":"my-python-app"}}'
```

Expected: `{ "success": true, "job": "python-ci", "repo": "my-python-app", "branch": "main" }`

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

Then restart only the proxy — no rebuild needed:

```powershell
docker-compose restart relay-proxy
```

---

## Tear Down

```powershell
docker-compose down -v   # -v removes all volumes (full reset)
```