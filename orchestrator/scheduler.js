#!/usr/bin/env node
/**
 * Multi-host session scheduler
 * Implements placement logic for distributed session management
 * Based on docs/scaling-strategy.md §3 placement service design
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

// Host registry - in production this would be a database
const HOST_REGISTRY = path.join(__dirname, 'hosts.json');
const SESSION_REGISTRY = path.join(__dirname, 'sessions.json');

// SSoT limits reading (FR-06 parity)
function readEnvFile(p) {
  const out = {};
  if (fs.existsSync(p)) {
    for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
      const m = line.match(/^([A-Z_]+)=(\S+)/);
      if (m) out[m[1]] = m[2];
    }
  }
  return out;
}

function parseMem(val) {
  if (!val) return 0;
  const s = String(val).toLowerCase();
  if (s.endsWith('g')) return parseFloat(s) * 1024;
  if (s.endsWith('m')) return parseFloat(s);
  return parseFloat(s);
}

const LIMITS = readEnvFile(path.join(__dirname, 'limits.env'));
const RAM_PER_PAIR = parseMem(LIMITS.ATTACKER_MEMORY || '512m') + parseMem(LIMITS.TARGET_MEMORY || '256m');
const CPU_PER_PAIR = parseFloat(LIMITS.ATTACKER_CPUS || '1.0') + parseFloat(LIMITS.TARGET_CPUS || '0.5');
const PIDS_PER_PAIR = parseInt(LIMITS.ATTACKER_PIDS_LIMIT || '100', 10) + parseInt(LIMITS.TARGET_PIDS_LIMIT || '50', 10);
const DISK_PER_PAIR = 50; // MB marginal disk per session pair

// Load registries or initialize empty
let hosts = {};
let sessions = {};

try {
  if (fs.existsSync(HOST_REGISTRY)) {
    hosts = JSON.parse(fs.readFileSync(HOST_REGISTRY, 'utf8'));
  }
} catch (e) {
  console.error('Error loading hosts registry:', e.message);
}

try {
  if (fs.existsSync(SESSION_REGISTRY)) {
    sessions = JSON.parse(fs.readFileSync(SESSION_REGISTRY, 'utf8'));
  }
} catch (e) {
  console.error('Error loading sessions registry:', e.message);
}

/**
 * Calculate host score for placement decision
 * Score = max(committed-RAM %, PID %, disk %)
 * Lower score = better placement
 */
function calculateHostScore(host) {
  const ramPercent = (host.usedRam / host.totalRam) * 100;
  const pidPercent = (host.usedPids / host.totalPids) * 100;
  const diskPercent = (host.usedDisk / host.totalDisk) * 100;
  
  return Math.max(ramPercent, pidPercent, diskPercent);
}

/**
 * Find best host for new session
 * Returns host with lowest score that stays under 80% admission line
 */
function findBestHost() {
  const admissionThreshold = 80;
  let bestHost = null;
  let bestScore = Infinity;
  
  for (const [hostId, host] of Object.entries(hosts)) {
    const score = calculateHostScore(host);
    
    // Check if host is under admission threshold
    if (score < admissionThreshold && score < bestScore) {
      bestHost = hostId;
      bestScore = score;
    }
  }
  
  return bestHost;
}

/**
 * Register a new host
 */
function registerHost(hostId, hostConfig) {
  hosts[hostId] = {
    id: hostId,
    url: hostConfig.url,
    totalRam: hostConfig.totalRam || 32 * 1024, // Default 32GB
    usedRam: hostConfig.usedRam || 0,
    totalCpu: hostConfig.totalCpu || 8,
    usedCpu: hostConfig.usedCpu || 0,
    totalPids: hostConfig.totalPids || 6000,
    usedPids: hostConfig.usedPids || 0,
    totalDisk: hostConfig.totalDisk || 500 * 1024, // Default 500GB
    usedDisk: hostConfig.usedDisk || 0,
    lastHeartbeat: Date.now()
  };
  
  saveRegistries();
  return hosts[hostId];
}

/**
 * Update host resource usage
 */
function updateHostUsage(hostId, usage) {
  if (!hosts[hostId]) return null;
  
  if (usage.ramDelta) hosts[hostId].usedRam += usage.ramDelta;
  if (usage.cpuDelta) hosts[hostId].usedCpu += usage.cpuDelta;
  if (usage.pidDelta) hosts[hostId].usedPids += usage.pidDelta;
  if (usage.diskDelta) hosts[hostId].usedDisk += usage.diskDelta;
  
  hosts[hostId].lastHeartbeat = Date.now();
  saveRegistries();
  return hosts[hostId];
}

/**
 * Allocate session to host
 */
function allocateSession(sessionId, bundle) {
  const hostId = findBestHost();
  
  if (!hostId) {
    return { error: 'No available host under admission threshold' };
  }
  
  // Update host usage using SSoT constants derived from limits.env
  updateHostUsage(hostId, {
    ramDelta: RAM_PER_PAIR,
    cpuDelta: CPU_PER_PAIR,
    pidDelta: PIDS_PER_PAIR,
    diskDelta: DISK_PER_PAIR
  });
  
  // Register session
  sessions[sessionId] = {
    id: sessionId,
    bundle: bundle,
    hostId: hostId,
    createdAt: Date.now(),
    status: 'allocated'
  };
  
  saveRegistries();
  
  return {
    sessionId,
    hostId,
    hostUrl: hosts[hostId].url,
    score: calculateHostScore(hosts[hostId])
  };
}

/**
 * Deallocate session from host
 */
function deallocateSession(sessionId) {
  const session = sessions[sessionId];
  if (!session) return { error: 'Session not found' };
  
  const hostId = session.hostId;
  if (!hosts[hostId]) return { error: 'Host not found' };
  
  // Update host usage (decrement using SSoT constants derived from limits.env)
  updateHostUsage(hostId, {
    ramDelta: -RAM_PER_PAIR,
    cpuDelta: -CPU_PER_PAIR,
    pidDelta: -PIDS_PER_PAIR,
    diskDelta: -DISK_PER_PAIR
  });
  
  // Remove session
  delete sessions[sessionId];
  saveRegistries();
  
  return { success: true, sessionId };
}

/**
 * Save registries to disk
 */
function saveRegistries() {
  try {
    fs.writeFileSync(HOST_REGISTRY, JSON.stringify(hosts, null, 2));
    fs.writeFileSync(SESSION_REGISTRY, JSON.stringify(sessions, null, 2));
  } catch (e) {
    console.error('Error saving registries:', e.message);
  }
}

/**
 * HTTP API for scheduler
 */
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;
  
  try {
    if (pathname === '/hosts' && req.method === 'POST') {
      const body = [];
      req.on('data', chunk => body.push(chunk));
      req.on('end', () => {
        const config = JSON.parse(body.join(''));
        const hostId = config.id || `host-${Date.now()}`;
        const host = registerHost(hostId, config);
        res.writeHead(201);
        res.end(JSON.stringify(host));
      });
      
    } else if (pathname === '/hosts' && req.method === 'GET') {
      res.writeHead(200);
      res.end(JSON.stringify(hosts));
      
    } else if (pathname.match(/^\/hosts\/[^/]+$/) && req.method === 'PUT') {
      const hostId = pathname.split('/')[2];
      const body = [];
      req.on('data', chunk => body.push(chunk));
      req.on('end', () => {
        const usage = JSON.parse(body.join(''));
        const host = updateHostUsage(hostId, usage);
        if (host) {
          res.writeHead(200);
          res.end(JSON.stringify(host));
        } else {
          res.writeHead(404);
          res.end(JSON.stringify({ error: 'Host not found' }));
        }
      });
      
    } else if (pathname === '/allocate' && req.method === 'POST') {
      const body = [];
      req.on('data', chunk => body.push(chunk));
      req.on('end', () => {
        const { sessionId, bundle } = JSON.parse(body.join(''));
        const result = allocateSession(sessionId, bundle);
        if (result.error) {
          res.writeHead(503);
          res.end(JSON.stringify(result));
        } else {
          res.writeHead(200);
          res.end(JSON.stringify(result));
        }
      });
      
    } else if (pathname.match(/^\/sessions\/[^/]+$/) && req.method === 'DELETE') {
      const sessionId = pathname.split('/')[2];
      const result = deallocateSession(sessionId);
      if (result.error) {
        res.writeHead(404);
        res.end(JSON.stringify(result));
      } else {
        res.writeHead(200);
        res.end(JSON.stringify(result));
      }
      
    } else if (pathname === '/sessions' && req.method === 'GET') {
      res.writeHead(200);
      res.end(JSON.stringify(sessions));
      
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Not found' }));
    }
    
  } catch (e) {
    console.error('Request error:', e);
    res.writeHead(500);
    res.end(JSON.stringify({ error: e.message }));
  }
});

const PORT = process.env.SCHEDULER_PORT || 8081;
server.listen(PORT, () => {
  console.log(`Multi-host scheduler running on port ${PORT}`);
  console.log(`Registered hosts: ${Object.keys(hosts).length}`);
  console.log(`Active sessions: ${Object.keys(sessions).length}`);
  console.log(`Limits from SSoT: RAM=${RAM_PER_PAIR}MB CPU=${CPU_PER_PAIR} PIDs=${PIDS_PER_PAIR} Disk=${DISK_PER_PAIR}MB`);
});

module.exports = {
  registerHost,
  updateHostUsage,
  allocateSession,
  deallocateSession,
  findBestHost,
  calculateHostScore
};
