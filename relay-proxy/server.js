'use strict';

const express = require('express');
const yaml = require('js-yaml');
const fs = require('fs');
const axios = require('axios');

const app = express();
app.use(express.json({ limit: '10mb' }));

// Load routing config at startup
const routingConfig = yaml.load(fs.readFileSync('./config/routing.yaml', 'utf8'));

const GITLAB_SECRET   = process.env.GITLAB_WEBHOOK_SECRET || '';
const JENKINS_URL     = process.env.JENKINS_URL     || 'http://jenkins:8080';
const JENKINS_USER    = process.env.JENKINS_USER    || 'admin';
const JENKINS_PASSWORD = process.env.JENKINS_PASSWORD || 'admin123';

// Find the first routing rule that matches repo + branch
function findRoute(repoName, branch) {
  return routingConfig.routes.find(r => {
    const repoMatch   = r.repo   === '*' || r.repo   === repoName;
    const branchMatch = r.branch === '*' || r.branch === branch;
    return repoMatch && branchMatch;
  });
}

// Call Jenkins REST API with CSRF crumb + session cookie
async function triggerJenkins(jobName) {
  const auth = { username: JENKINS_USER, password: JENKINS_PASSWORD };

  // Fetch crumb and capture the session cookie from the same response
  const crumbRes = await axios.get(`${JENKINS_URL}/crumbIssuer/api/json`, { auth });
  const { crumbRequestField, crumb } = crumbRes.data;

  // Jenkins binds the crumb to the session — must send the same session cookie
  const rawCookies = crumbRes.headers['set-cookie'] || [];
  const cookieHeader = rawCookies.map(c => c.split(';')[0]).join('; ');

  await axios.post(
    `${JENKINS_URL}/job/${encodeURIComponent(jobName)}/build`,
    null,
    {
      auth,
      headers: {
        [crumbRequestField]: crumb,
        ...(cookieHeader && { Cookie: cookieHeader }),
      },
    }
  );
}

// Health probe
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'relay-proxy', timestamp: new Date().toISOString() });
});

// Inspect loaded routes (useful for debugging)
app.get('/routes', (_req, res) => {
  res.json(routingConfig);
});

// Main webhook receiver
app.post('/webhook', async (req, res) => {
  // Validate GitLab secret token
  const token = req.headers['x-gitlab-token'];
  if (GITLAB_SECRET && token !== GITLAB_SECRET) {
    console.warn(`[WARN] Unauthorized webhook attempt - invalid token`);
    return res.status(401).json({ error: 'Unauthorized: invalid token' });
  }

  const payload   = req.body;
  const eventType = req.headers['x-gitlab-event'] || 'unknown';
  const repoName  = payload.repository?.name || payload.project?.name || '';
  const ref       = payload.ref || '';
  const branch    = ref.replace('refs/heads/', '');

  console.log(`[${new Date().toISOString()}] Event="${eventType}" Repo="${repoName}" Branch="${branch}"`);

  if (!repoName || !branch) {
    return res.status(400).json({ error: 'Cannot determine repo or branch from payload' });
  }

  const route = findRoute(repoName, branch);
  if (!route) {
    console.log(`[INFO] No route matched for ${repoName}:${branch} — ignoring`);
    return res.json({ message: 'No matching route', repo: repoName, branch });
  }

  console.log(`[INFO] Routing ${repoName}:${branch}  →  Jenkins job: ${route.jenkins_job}`);

  try {
    await triggerJenkins(route.jenkins_job);
    console.log(`[OK] Triggered Jenkins job: ${route.jenkins_job}`);
    res.json({ success: true, job: route.jenkins_job, repo: repoName, branch });
  } catch (err) {
    const detail = err.response?.data || err.message;
    console.error(`[ERROR] Failed to trigger Jenkins: ${JSON.stringify(detail)}`);
    res.status(500).json({ error: 'Failed to trigger Jenkins', detail });
  }
});

app.listen(3000, () => {
  console.log('RelayProxy listening on http://0.0.0.0:3000');
  console.log(`Routes loaded: ${routingConfig.routes.length}`);
  routingConfig.routes.forEach(r =>
    console.log(`  repo="${r.repo}"  branch="${r.branch}"  →  job="${r.jenkins_job}"`)
  );
});
