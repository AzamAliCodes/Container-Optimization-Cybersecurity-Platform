#!/bin/bash
# Quick benchmark for live testing
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Quick Benchmark Run ==="
echo "Testing optimized containers on current hardware"
echo ""

# Get current hardware info
echo "Hardware Info:"
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "CPU: $(sysctl -n hw.ncpu) cores"
    echo "Memory: $(sysctl -n hw.memsize) bytes ($(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024)) GB)"
else
    echo "CPU: $(nproc) cores"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
fi
echo ""

# Test image sizes
echo "=== Image Sizes ==="
ATTACKER_SIZE=$(docker image inspect --format '{{.Size}}' platform/web-exploitation:phase1 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
TARGET_SIZE=$(docker image inspect --format '{{.Size}}' platform/target:phase1 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
echo "Attacker: ${ATTACKER_SIZE} MiB"
echo "Target: ${TARGET_SIZE} MiB"
echo ""

# Test cold start times (simplified)
echo "=== Cold Start Times ==="
TIMES_FILE="/tmp/quick-bench-times.txt"
> "$TIMES_FILE"

for i in {1..3}; do
    echo "Run $i:"
    
    # Create network
    docker network create "quick-bench-net-$i" >/dev/null 2>&1 || true
    
    # Start timing
    START=$(python3 -c 'import time; print(int(time.time()*1000))')
    
    # Start attacker
    docker run -d --name "quick-bench-att-$i" --network "quick-bench-net-$i" \
        platform/web-exploitation:phase1 >/dev/null 2>&1
    
    # Start target
    docker run -d --name "quick-bench-tgt-$i" --network "quick-bench-net-$i" \
        platform/target:phase1 >/dev/null 2>&1
    
    # Wait for target to be healthy
    echo "  Waiting for target health..."
    TIMEOUT=0
    while ! docker inspect --format '{{.State.Health.Status}}' "quick-bench-tgt-$i" 2>/dev/null | grep -q healthy; do
        sleep 0.5
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 60 ]; then
            echo "  Timeout after 30s"
            break
        fi
    done
    
    END=$(python3 -c 'import time; print(int(time.time()*1000))')
    DURATION=$((END - START))
    echo "$DURATION" >> "$TIMES_FILE"
    echo "  Duration: ${DURATION}ms"
    
    # Cleanup
    docker rm -f "quick-bench-att-$i" "quick-bench-tgt-$i" >/dev/null 2>&1 || true
    docker network rm "quick-bench-net-$i" >/dev/null 2>&1 || true
done

# Calculate median
if [ -s "$TIMES_FILE" ]; then
    MEDIAN=$(sort -n "$TIMES_FILE" | awk 'NR==2')
    echo "Median cold start: ${MEDIAN}ms"
else
    echo "No successful cold start measurements"
fi
rm "$TIMES_FILE"
echo ""

# Test idle resource usage
echo "=== Idle Resource Usage ==="
docker network create "quick-bench-net" >/dev/null 2>&1 || true
docker run -d --name "quick-bench-att" --network "quick-bench-net" \
    platform/web-exploitation:phase1 >/dev/null 2>&1
docker run -d --name "quick-bench-tgt" --network "quick-bench-net" \
    platform/target:phase1 >/dev/null 2>&1

echo "Waiting for containers to settle..."
sleep 10

echo "Container Stats:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}" | grep -E "NAME|quick-bench"

# Get process counts
ATT_PROCS=$(docker top quick-bench-att -o pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
TGT_PROCS=$(docker top quick-bench-tgt -o pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
echo "Attacker processes: $ATT_PROCS"
echo "Target processes: $TGT_PROCS"

# Cleanup
docker rm -f quick-bench-att quick-bench-tgt >/dev/null 2>&1 || true
docker network rm quick-bench-net >/dev/null 2>&1 || true

echo ""
echo "=== Quick Benchmark Complete ==="
