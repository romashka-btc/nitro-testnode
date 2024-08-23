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

# enter orbit actions directory to run deployment scripts
cd orbit-actions

#forge script to deploy new OSP entry and upgrade actions
NEW_OSP_ENTRY=`forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOsp.s.sol:DeployEspressoOsp --rpc-url $RPC_URL --broadcast --verify -vvvv --verifier blockscout --verifier-url http://localhost:4000/api? | tail -n 11 | grep "/0x" | cut -c 37-80 | tr -d '\r\n'`
echo $NEW_OSP_ENTRY
export NEW_OSP_ENTRY

#forge script to deploy Espresso osp migration action
forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOspMigrationAction.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv --verifier blockscout --verifier-url http://localhost:4000/api?

#forge script to deploy the Espresso ArbOS upgrade acdtion.
forge script --chain $L2_CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployArbOSUpgradeAction.s.sol --rpc-url $L2_RPC_URL --broadcast --verify -vvvv --verifier blockscout --verifier-url http://localhost:4000/api?

# use cast to call the upgradeExecutor to execute the l1 upgrade actions.

cast send $UPGRADE_EXECUTOR "execute(address, bytes)" $UPGRADE_ACTION_ADDRESS $(cast calldata "perform()") --rpc-url $CHILD_CHAIN_RPC --account EXECUTOR)
# use --account XXX / --private-key XXX / --interactive / --ledger to set the account to send the transaction from

#check the upgrade happened


#./test-node.bash --espresso --latest-espresso-image --validate --tokenbridge --init --detach
