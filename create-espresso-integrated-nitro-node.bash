#!/usr/bin/env bash
set -euo pipefail

ESPRESSO_VERSION=ghcr.io/espressosystems/nitro-espresso-integration/nitro-node-dev:integration

# docker pull and tag the espresso integration nitro node.
docker pull $ESPRESSO_VERSION

docker tag $ESPRESSO_VERSION espresso-integration-testnode

# write the espresso configs to the config volume
echo == Writing configs
docker compose run scripts write-config --espresso $espresso --lightClientAddress $lightClientAddr

# do whatever other espresso setup is needed.