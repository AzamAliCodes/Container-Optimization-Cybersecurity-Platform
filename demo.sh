#!/bin/bash
cd "$(dirname "$0")"

echo "=== Container Optimization Platform Demo ==="
echo ""

# Check if API is already running
if curl -s http://localhost:8080/sessions > /dev/null 2>&1; then
    echo "✓ API already running on port 8080"
    API_PID=""
else
    echo "1. Starting Orchestrator API..."
    PORT=8080 node orchestrator/api.js &
    API_PID=$!
    sleep 3
fi

echo ""
echo "2. Creating demo session..."
curl -s -X POST localhost:8080/sessions \
  -H 'content-type: application/json' \
  -d '{"bundle":"web-exploitation","id":"tech-lead-demo"}'

echo ""
echo "3. Session Status:"
curl -s localhost:8080/sessions/tech-lead-demo | jq '.'

echo ""
echo "4. Running Containers:"
docker ps | grep tech-lead-demo

echo ""
echo "5. Resource Usage:"
docker stats --no-stream | grep tech-lead-demo

echo ""
echo "6. Network Isolation:"
docker network ls | grep tech-lead-demo

echo ""
echo "7. Testing connectivity between containers:"
docker exec sess-tech-lead-demo-attacker nc -z sess-tech-lead-demo-target 8080 && echo "✓ Attacker can reach target on port 8080"

echo ""
echo "8. Cleanup - deleting session..."
curl -s -X DELETE localhost:8080/sessions/tech-lead-demo

echo ""
echo "9. Final container status:"
docker ps | grep tech-lead-demo || echo "✓ All demo containers cleaned up"

echo ""
echo "=== Demo Complete ==="

# Only kill API if we started it
if [ -n "$API_PID" ]; then
    kill $API_PID 2>/dev/null || true
fi
