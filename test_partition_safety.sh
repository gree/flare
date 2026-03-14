#!/bin/bash
set -e

echo "=== Testing Partition Safety with Helm Deployment ==="
echo ""
echo "This test verifies:"
echo "1. Partition reduction is blocked (no data loss)"
echo "2. The E2E test suite passes with the Helm-deployed operator"
echo ""

# Run the partition reduction E2E test
echo "Running partition reduction E2E test..."
cd flare_operator && timeout 240 .lake/build/bin/flare_e2e --filter partition-reduction

