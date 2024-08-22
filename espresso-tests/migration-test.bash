#!/usr/bin/env bash
set -euo pipefail

#change to the test node directory
cd ..

#Initialize a standard network not compatible with espresso
./test-node.bash --simple --init --blockscout --detach 

#start espresso sequencer node
docker compose up espresso-dev-node --detach



#shutdown nitro node
docker stop nitro-testnode-sequencer-1

#start nitro node in new docker container with espresso image (create a new script to do this from pieces of test-node.bash)
./espresso-tests/create-espresso-integrated-nitro-node.bash 

# enter the directory for the appropriate .env file
cd espresso-tests
# source the env file to export required
source .env
## return to top level directory    
cd ..

#export l2 owner private key
export PRIVATE_KEY=`docker compose run scripts print-private-key --account l2owner | tail -n 1 | tr -d '\r\n'`

# stupidly precise command to extract the upgrade-executors-address so that we can pass it to the test script.
#UPGRADE_EXECUTOR='docker compose run scripts print-upgrade-executor-address | tail -n 6 | grep "upgrade" | cut -c 28-69' #if anything changes about the specific positions arbitrum writes data to json files this WILL break.
#echo $UPGRADE_EXECUTOR
#export UPGRADE_EXECUTOR

# enter orbit actions directory to run deployment scripts
cd orbit-actions

#forge script to deploy new OSP entry and upgrade actions
NEW_OSP_ENTRY=`forge script --chain $CHAIN_NAME ../orbit-actions/contracts/parent-chain/contract-upgrades/DeployEspressoOsp.s.sol:DeployEspressoOsp --rpc-url $RPC_URL --broadcast --verify -vvvv --verifier blockscout --verifier-url http://localhost:4000/api? | tail -n 11 | grep "/0x" | cut -c 37-80 | tr -d '\r\n'`
echo $NEW_OSP_ENTRY
export NEW_OSP_ENTRY

#forge script to execute upgrade actions
forge script --chain $CHAIN_NAME ../orbit-actions/contracts/parent-chain/contract-upgrades/DeployAndExecuteEspressoMigrationActions.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv --verifier blockscout --verifier-url http://localhost:4000/api?
#check the upgrade happened


#./test-node.bash --espresso --latest-espresso-image --validate --tokenbridge --init --detach
