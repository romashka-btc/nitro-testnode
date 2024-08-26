#!/usr/bin/env bash
set -euo pipefail
set -a # automatically export all variables
set -x # print each command before executing it, for debugging

# Find directory of this script
TEST_DIR="$(dirname $(readlink -f $0))"
TESTNODE_DIR="$(dirname "$TEST_DIR")"
ORBIT_ACTIONS_DIR="$TESTNODE_DIR/orbit-actions"

cd "$TESTNODE_DIR"

# Initialize a standard network not compatible with espresso
./test-node.bash --simple --init-force --detach

# Start espresso sequencer node
docker compose up espresso-dev-node --detach

# Export environment variables in .env file
. "$TEST_DIR/.env"

# Export l2 owner private key
PRIVATE_KEY="$(docker compose run scripts print-private-key --account l2owner | tail -n 1 | tr -d '\r\n')"

cd "$ORBIT_ACTIONS_DIR"

git submodule update --init
yarn

#echo for debug
echo "Deploying Espresso Osp"
#forge script to deploy new OSP entry and upgrade actions
forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOsp.s.sol:DeployEspressoOsp --rpc-url $RPC_URL --broadcast -vvvv

#extract new_osp_entry from run-latest.json
NEW_OSP_ENTRY=$(cat broadcast/DeployEspressoOsp.s.sol/1337/run-latest.json | jq -r '.transactions[4].contractAddress')

echo "Deployed new OspEntry at $NEW_OSP_ENTRY"

#echo for debug
echo "Deploying Espresso Osp migration action"

#forge script to deploy Espresso osp migration action
forge script --chain $CHAIN_NAME contracts/parent-chain/contract-upgrades/DeployEspressoOspMigrationAction.s.sol --rpc-url $RPC_URL --broadcast -vvvv

#capture new OSP address
OSP_MIGRATION_ACTION=$(cat broadcast/DeployEspressoOspMigrationAction.s.sol/1337/run-latest.json | jq -r '.transactions[0].contractAddress')

echo "Deployed new OspMigrationAction at $OSP_MIGRATION_ACTION"

# use cast to call the upgradeExecutor to execute the l1 upgrade actions.

cast send $UPGRADE_EXECUTOR "execute(address, bytes)" $OSP_MIGRATION_ACTION $(cast calldata "perform()") --rpc-url $RPC_URL --private-key $PRIVATE_KEY

echo "Executed OspMigrationAction via UpgradeExecutor"

#shutdown nitro node
docker stop nitro-testnode-sequencer-1

#start nitro node in new docker container with espresso image (create a new script to do this from pieces of test-node.bash)
cd $TESTNODE_DIR
./espresso-tests/create-espresso-integrated-nitro-node.bash

#echo for debug
echo "Deploying ArbOS action"

#forge script to deploy the Espresso ArbOS upgrade acdtion.
forge script --chain $L2_CHAIN_NAME contracts/child-chain/arbos-upgrade/DeployArbOSUpgradeAction.s.sol:DeployArbOSUpgradeAction  --rpc-url $L2_RPC_URL --broadcast -vvvv

ARBOS_UPGRADE_ACTION=$(cat broadcast/DeployEspressoOspMigrationAction.s.sol/412346/run-latest.json | jq -r '.transactions[0].contractAddress')



#check the upgrade happened


#./test-node.bash --espresso --latest-espresso-image --validate --tokenbridge --init --detach
