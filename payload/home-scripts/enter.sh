#!/bin/bash

name="${WORKENV}_$1"

# Filter only running containers to exclude stale/stopped ones (non-destructive)
ids=$(docker ps -qf "status=running" -f "name=${name}")

if [ -z "$ids" ]; then
  name="${WORKENV}-$1"
  ids=$(docker ps -qf "status=running" -f "name=${name}")
fi

if [ -z "$ids" ]; then
  echo "No running container found matching: ${WORKENV}_$1 or ${WORKENV}-$1"
  exit 1
fi

# Pick the first match (handles docker compose numeric suffixes e.g. service_1, service-1)
id=$(echo "$ids" | head -n 1)

echo "Entering $id"
docker exec -it "$id" /bin/sh
