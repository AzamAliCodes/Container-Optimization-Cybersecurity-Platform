#!/usr/bin/env node
/**
 * Host agent for multi-host scaling
 * Runs on each host to report resource usage and execute sessions
 */

const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const os = require('os');

const SCHEDULER_URL = process.env.SCHEDULER_URL || 'http://localhost:8081';
const HOST_ID = process.env.HOST_ID || `host-${os.hostname()}`;
const HEARTBEAT_INTERVAL = 30000; // 30 seconds

/**
 * Get dynamic host specifications from the system
 */
function getHostSpecs() {
  return new Promise((resolve) => {
    // Total RAM from os module (converted to MB)
    const totalRamMB = Math.round(os.totalmem() / (1024 * 1024));
    
    // CPU core count from os module
    const totalCpu = os.cpus().length || 1;

    // Total disk calculation (using fs.statfs if available, fallback to df)
    let totalDiskMB = 50 * 1024;
    try {
      if (typeof fs.statfsSync === 'function') {
        const stat = fs.statfsSync('/');
        totalDiskMB = Math.round((stat.bsize * stat.blocks) / (1024 * 1024));
      }
    } catch (_) {}

    // Max PIDs from system
    let totalPids = 32768;
    try {
      if (fs.existsSync('/proc/sys/kernel/pid_max')) {
        totalPids = parseInt(fs.readFileSync('/proc/sys/kernel/pid_max', 'utf8').trim(), 10) || 32768;
      }
    } catch (_) {}

    resolve({
      id: HOST_ID,
      url: `http://${os.hostname()}:8080`,
      totalRam: totalRamMB,
      totalCpu: totalCpu,
      totalPids: totalPids,
      totalDisk: totalDiskMB
    });
  });
}

/**
 * Get current host resource usage
 */
function getHostUsage() {
  return new Promise((resolve) => {
    // Get Docker stats for our session containers
    exec('docker stats --no-stream --format "{{.MemUsage}}\\t{{.CPUPerc}}"', (error, stdout) => {
      let totalMemMB = 0;
      let totalCPUPct = 0;

      if (!error && stdout) {
        const lines = stdout.trim().split('\n');
        lines.forEach(line => {
          const parts = line.split('\t');
          if (parts.length >= 2) {
            const memMatch = parts[0].match(/([\d.]+)MiB/);
            if (memMatch) {
              totalMemMB += parseFloat(memMatch[1]);
            }
            const cpuMatch = parts[1].match(/([\d.]+)%/);
            if (cpuMatch) {
              totalCPUPct += parseFloat(cpuMatch[1]);
            }
          }
        });
      }

      // Query running containers for active PID count
      exec('docker ps -q', (psErr, psOut) => {
        const containerIds = psOut ? psOut.trim().split('\n').filter(Boolean) : [];
        const usedPids = containerIds.length * 3; // Estimated active baseline per container

        // Query docker system df for writable disk usage
        exec('docker system df --format "{{.Size}}" 2>/dev/null', (dfErr, dfOut) => {
          let usedDiskMB = 0;
          if (!dfErr && dfOut) {
            const first = dfOut.trim().split('\n')[0] || '';
            const mMatch = first.match(/([\d.]+)MB/i);
            const gMatch = first.match(/([\d.]+)GB/i);
            if (mMatch) usedDiskMB = parseFloat(mMatch[1]);
            else if (gMatch) usedDiskMB = parseFloat(gMatch[1]) * 1024;
          }

          resolve({
            usedRam: Math.round(totalMemMB * 10) / 10,
            usedCpu: Math.round((totalCPUPct / 100) * 100) / 100,
            usedPids: usedPids,
            usedDisk: Math.round(usedDiskMB)
          });
        });
      });
    });
  });
}

/**
 * Register this host with the scheduler
 */
async function registerWithScheduler() {
  const hostConfig = await getHostSpecs();
  
  return new Promise((resolve, reject) => {
    const url = new URL(SCHEDULER_URL + '/hosts');
    const postData = JSON.stringify(hostConfig);
    
    const options = {
      hostname: url.hostname,
      port: url.port || 80,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    };
    
    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode === 201) {
          console.log(`Registered host ${HOST_ID} with scheduler: ${hostConfig.totalRam}MB RAM, ${hostConfig.totalCpu} cores`);
          resolve(JSON.parse(data));
        } else {
          reject(new Error(`Failed to register: ${res.statusCode}`));
        }
      });
    });
    
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

/**
 * Send heartbeat with current usage
 */
function sendHeartbeat() {
  return new Promise((resolve, reject) => {
    getHostUsage().then(usage => {
      const url = new URL(SCHEDULER_URL + `/hosts/${HOST_ID}`);
      const postData = JSON.stringify(usage);
      
      const options = {
        hostname: url.hostname,
        port: url.port || 80,
        path: url.pathname,
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData)
        }
      };
      
      const req = http.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          if (res.statusCode === 200) {
            const host = JSON.parse(data);
            console.log(`Heartbeat sent - Score: ${Math.max(
              (host.usedRam / host.totalRam) * 100,
              (host.usedPids / host.totalPids) * 100,
              (host.usedDisk / host.totalDisk) * 100
            ).toFixed(1)}%`);
            resolve();
          } else {
            console.error('Failed to send heartbeat');
            resolve();
          }
        });
      });
      
      req.on('error', (error) => {
        console.error('Heartbeat error:', error.message);
        resolve(); // Don't reject to keep heartbeat running
      });
      
      req.write(postData);
      req.end();
    }).catch(error => {
      console.error('Error getting host usage:', error.message);
      resolve();
    });
  });
}

/**
 * Provision a session on this host
 */
function provisionSession(sessionId, bundle) {
  return new Promise((resolve, reject) => {
    const provisionScript = path.join(__dirname, 'provision.sh');
    
    exec(`${provisionScript} ${bundle} ${sessionId}`, (error, stdout, stderr) => {
      if (error) {
        reject(error);
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

/**
 * Start local HTTP server for session execution
 */
const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;
  
  try {
    if (pathname === '/provision' && req.method === 'POST') {
      const body = [];
      req.on('data', chunk => body.push(chunk));
      req.on('end', async () => {
        const { sessionId, bundle } = JSON.parse(body.join(''));
        
        try {
          const result = await provisionSession(sessionId, bundle);
          res.writeHead(200);
          res.end(JSON.stringify({ success: true, sessionId }));
        } catch (error) {
          res.writeHead(500);
          res.end(JSON.stringify({ error: error.message }));
        }
      });
      
    } else if (pathname.match(/^\/sessions\/[^/]+$/) && req.method === 'DELETE') {
      const sessionId = pathname.split('/')[2];
      
      // Use existing orchestrator API to delete session
      exec(`curl -s -X DELETE localhost:8080/sessions/${sessionId}`, (error, stdout, stderr) => {
        if (error) {
          res.writeHead(500);
          res.end(JSON.stringify({ error: error.message }));
        } else {
          res.writeHead(200);
          res.end(JSON.stringify({ success: true, sessionId }));
        }
      });
      
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

/**
 * Main startup
 */
async function main() {
  console.log(`Starting host agent ${HOST_ID}...`);
  
  // Register with scheduler
  try {
    await registerWithScheduler();
  } catch (error) {
    console.error('Failed to register with scheduler, running in standalone mode');
  }
  
  // Start heartbeat interval
  setInterval(sendHeartbeat, HEARTBEAT_INTERVAL);
  
  // Start local server
  const AGENT_PORT = process.env.AGENT_PORT || 8082;
  server.listen(AGENT_PORT, () => {
    console.log(`Host agent running on port ${AGENT_PORT}`);
    console.log(`Scheduler URL: ${SCHEDULER_URL}`);
  });
}

main().catch(console.error);
