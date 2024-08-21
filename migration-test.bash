#!/usr/bin/env bash
set -euo pipefail


#Initialize a standard network not compatible with espresso.
./test-node.bash --simple --init --detach 

#start espresso sequencer node
docker compose up espresso-dev-node --detach

#shutdown nitro node
docker stop nitro-testnode-sequencer-1

#start nitro node in new docker container with espresso image (create a new script to do this from pieces of test-node.bash)
./create-espresso-integrated-nitro-node.bash 

#forge script to deploy new OSP entry and upgrade actions

#forge script to execute upgrade actions

#check the upgrade happened.


#./test-node.bash --espresso --latest-espresso-image --validate --tokenbridge --init --detach
