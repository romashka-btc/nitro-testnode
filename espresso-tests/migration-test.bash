#!/usr/bin/env bash
set -euoa pipefail

#change to the test node directory
cd ..

#Initialize a standard network not compatible with espresso
./test-node.bash --simple --init --detach 

#start espresso sequencer node
docker compose up espresso-dev-node --detach

# enter the directory for the appropriate .env file
cd espresso-tests
# source the env file to export required
. .env

cd ..

#export l2 owner private key
PRIVATE_KEY=$(docker compose run scripts print-private-key --account l2owner | tail -n 1 | tr -d '\r\n')

# enter orbit actions directory to run deployment scripts
cd orbit-actions

#echo for debug
echo "Deploying Espresso Osp"
#forge script to deploy new OSP entry and upgrade actions
forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOsp.s.sol:DeployEspressoOsp --rpc-url $RPC_URL --broadcast -vvvv

#extract new_osp_entry from run-latest.json
NEW_OSP_ENTRY=$(cd broadcast/DeployEspressoOsp.s.sol/1337; cat run-latest.json | jq -r '.transactions[4].contractAddress')

#echo for debug
echo "Deploying Espresso Osp migration action"

#forge script to deploy Espresso osp migration action 
forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOspMigrationAction.s.sol --rpc-url $RPC_URL --broadcast -vvvv

#capture new OSP address
OSP_MIGRATION_ACTION=$(cd broadcast/DeployEspressoOspMigrationAction.s.sol/1337; cat run-latest.json | jq -r '.transactions[0].contractAddress')

# use cast to call the upgradeExecutor to execute the l1 upgrade actions.

cast send $UPGRADE_EXECUTOR "execute(address, bytes)" 0x773D62Ce1794b11788907b32F793e647A4f9A1F7 $(cast calldata "perform()") --rpc-url $RPC_URL --private-key $PRIVATE_KEY

#shutdown nitro node
docker stop nitro-testnode-sequencer-1

#start nitro node in new docker container with espresso image (create a new script to do this from pieces of test-node.bash)
cd ..; ./espresso-tests/create-espresso-integrated-nitro-node.bash 

#echo for debug
echo "Deploying ArbOS action"

#forge script to deploy the Espresso ArbOS upgrade acdtion.
forge script --chain $L2_CHAIN_NAME contracts/child-chain/arbos-upgrade/DeployArbOSUpgradeAction.s.sol:DeployArbOSUpgradeAction  --rpc-url $L2_RPC_URL --broadcast -vvvv

ARBOS_UPGRADE_ACTION=$(cd broadcast/DeployEspressoOspMigrationAction.s.sol/412346; cat run-latest.json | jq -r '.transactions[0].contractAddress')



#check the upgrade happened


#./test-node.bash --espresso --latest-espresso-image --validate --tokenbridge --init --detach
