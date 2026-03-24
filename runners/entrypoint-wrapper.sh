#!/bin/bash
# Read secrets from mounted files into environment
# APP_ID and APP_PRIVATE_KEY are used for registration (entrypoint strips them after)
# DOCKERHUB_TOKEN and GITOPS_PAT persist for workflow steps

export APP_ID=$(cat /run/secrets/github-app-arc-id)
export APP_PRIVATE_KEY=$(cat /run/secrets/github-app-arc-private-key)
export DOCKERHUB_TOKEN=$(cat /run/secrets/docker-hub-k3s-runner-api-key)
export GITOPS_PAT=$(cat /run/secrets/github-pat-k3s-dean-gitops)

exec /entrypoint.sh "$@"
