#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
WORKFLOW="Build Backend EXE"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is not installed."
  echo "Install it from https://cli.github.com/ then run:"
  echo "  gh auth login"
  exit 1
fi

cd "$REPO_ROOT"

echo "Triggering GitHub Actions workflow: $WORKFLOW"
gh workflow run "$WORKFLOW"

echo "Waiting for workflow run to start..."
sleep 8

RUN_ID="$(gh run list --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "Could not find workflow run."
  exit 1
fi

echo "Watching run $RUN_ID..."
gh run watch "$RUN_ID"

STATUS="$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')"
if [[ "$STATUS" != "success" ]]; then
  echo "Workflow failed. Open GitHub Actions for details."
  exit 1
fi

OUT_DIR="$ROOT/release/github-exe"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*

echo "Downloading salesman-api-windows artifact..."
gh run download "$RUN_ID" --name salesman-api-windows --dir "$OUT_DIR"

echo ""
echo "Download complete:"
ls -la "$OUT_DIR"
echo ""
echo "Copy salesman-api.exe, .env.example, and start-api.bat to your Windows server."
echo "On the server: copy .env.example .env and edit DB_PASSWORD."
