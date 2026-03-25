#!/bin/bash
set -ex
cd "$(dirname "$0")/../optimism"
echo "Go version: $(go version)"
echo "Building op-proposer from $(git log --oneline -1 2>/dev/null || echo 'unknown commit')..."
go build -o ../bin/op-proposer ./op-proposer/cmd
echo "Build complete!"
ls -la ../bin/op-proposer
../bin/op-proposer --help 2>&1 | grep -E 'l2oo|game-factory' || echo "no matching flags found"
