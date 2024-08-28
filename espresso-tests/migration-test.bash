#!/usr/bin/env bash

fail(){
    echo "$*" 1>&2; exit 1;
}

set -euo pipefail
set -a # automatically export all variables
set -x # print each command before executing it, for debugging



# Find directory of this script
TEST_DIR="$(dirname $(readlink -f $0))"
TESTNODE_DIR="$(dirname "$TEST_DIR")"
ORBIT_ACTIONS_DIR="$TESTNODE_DIR/orbit-actions"

cd "$TESTNODE_DIR"

# Initialize a standard network not compatible with espresso
./test-node.bash --simple --init-force --tokenbridge --detach

# Start espresso sequencer node
docker compose up espresso-dev-node --detach

# Export environment variables in .env file
. "$TEST_DIR/.env"

# Overwrite the ROLLUP_ADDRESS for this test, it might not be the same as the one in the .env file
ROLLUP_ADDRESS=$(docker compose run --entrypoint cat scripts /config/deployed_chain_info.json | jq -r '.[0].rollup.rollup' | tail -n 1 | tr -d '\r\n')

# A convoluted way to get the address of the child chain upgrade executor, maybe there's a better way?
INBOX_ADDRESS=$(docker compose run --entrypoint cat scripts /config/deployed_chain_info.json | jq -r '.[0].rollup.inbox' | tail -n 1 | tr -d '\r\n')
L1_TOKEN_BRIDGE_CREATOR_ADDRESS=$(docker compose run --entrypoint cat scripts /tokenbridge-data/network.json | jq -r '.l1TokenBridgeCreator' | tail -n 1 | tr -d '\r\n')
CHILD_CHAIN_UPGRADE_EXECUTOR_ADDRESS=$(cast call $L1_TOKEN_BRIDGE_CREATOR_ADDRESS 'inboxToL2Deployment(address)(address,address,address,address,address,address,address,address,address)' $INBOX_ADDRESS | tail -n 2 | head -n 1 | tr -d '\r\n')

# Export l2 owner private key and address
PRIVATE_KEY="$(docker compose run scripts print-private-key --account l2owner | tail -n 1 | tr -d '\r\n')"
OWNER_ADDRESS="$(docker compose run scripts print-address --account l2owner | tail -n 1 | tr -d '\r\n')"


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

NUM_CONFIRMED_NODES_BEFORE_UPGRADE=$(cast call --rpc-url $RPC_URL $ROLLUP_ADDRESS 'latestConfirmed()(uint256)')
#shutdown nitro node
docker stop nitro-testnode-sequencer-1

#start nitro node in new docker container with espresso image (create a new script to do this from pieces of test-node.bash)
cd $TESTNODE_DIR
./espresso-tests/create-espresso-integrated-nitro-node.bash

# Wait for RPC_URL to be available
while ! curl -s $L2_RPC_URL > /dev/null; do
  echo "Waiting for $L2_RPC_URL to be available..."
  sleep 5
done

echo "Adding child chain upgrade executor as an L2 chain owner"
cast send 0x0000000000000000000000000000000000000070 'addChainOwner(address)' $CHILD_CHAIN_UPGRADE_EXECUTOR_ADDRESS --rpc-url $L2_RPC_URL --private-key $PRIVATE_KEY

echo "Deploying ArbOS action"

#forge script to deploy the Espresso ArbOS upgrade action.
cd $ORBIT_ACTIONS_DIR
forge script --chain $L2_CHAIN_NAME contracts/child-chain/arbos-upgrade/DeployArbOSUpgradeAction.s.sol:DeployArbOSUpgradeAction  --rpc-url $L2_RPC_URL --broadcast -vvvv
ARBOS_UPGRADE_ACTION=$(cat broadcast/DeployArbOSUpgradeAction.s.sol/412346/run-latest.json | jq -r '.transactions[0].contractAddress')
echo "Deployed ArbOSUpgradeAction at $ARBOS_UPGRADE_ACTION"

# TODO: figure out why this upgrade does not do anything
cast send $CHILD_CHAIN_UPGRADE_EXECUTOR_ADDRESS "execute(address, bytes)" $ARBOS_UPGRADE_ACTION $(cast calldata "perform()") --rpc-url $L2_RPC_URL --private-key $PRIVATE_KEY

ARBOS_VERSION_BEFORE_UPGRADE=$(cast call "0x0000000000000000000000000000000000000064" "arbOSVersion()(uint64)" --rpc-url $L2_RPC_URL)

# Check the upgrade happened

ARBOS_VERSION_AFTER_UPGRADE=$(cast call "0x0000000000000000000000000000000000000064" "arbOSVersion()(uint64)" --rpc-url $L2_RPC_URL)

while [ $ARBOS_VERSION_BEFORE_UPGRADE == $ARBOS_VERSION_AFTER_UPGRADE ]
do
  sleep 5
  ARBOS_VERSION_AFTER_UPGRADE=$(cast call "0x0000000000000000000000000000000000000064" "arbOSVersion()(uint64)" --rpc-url $L2_RPC_URL)
done

# The arbsys precompile is returning 55 for the arbos version which indicates that the value internally is 0
# We are upgrading the ArbOS version to 35 so the expect the return value to be 55 + 35 = 90
if [ $ARBOS_VERSION_AFTER_UPGRADE != "90" ]; then
  fail "ArbOS version not updated: Expected 90, Actual $ARBOS_VERSION_AFTER_UPGRADE"
fi

#test for new OSP address
CHALLENGE_MANAGER_OSP_ADDRESS=$(cast call $CHALLENGE_MANAGER_ADDRESS "osp()(address)" --rpc-url $RPC_URL)
if [ $NEW_OSP_ENTRY != $CHALLENGE_MANAGER_OSP_ADDRESS ]; then
  fail "OSP has not been set to newly deployed OSP: \n Newly deployed: $NEW_OSP_ENTRY \n Currently set OSP: $CHALLENGE_MANAGER_OSP_ADDRESS"
fi
# check for balance update and transactions actually being sequenced
ORIGINAL_OWNER_BALANCE=$(cast balance $OWNER_ADDRESS -e --rpc-url $L2_RPC_URL)

# Send 1 eth as the owner
RECIPIENT_ADDRESS=0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
BALANCE_ORIG=$(cast balance $RECIPIENT_ADDRESS -e --rpc-url $L2_RPC_URL)
cast send $RECIPIENT_ADDRESS --value 1ether --rpc-url $L2_RPC_URL --private-key $PRIVATE_KEY

BALANCE_NEW=$(cast balance $RECIPIENT_ADDRESS -e --rpc-url $L2_RPC_URL)

if [ $BALANCE_NEW == $BALANCE_ORIG ]; then
  fail "Balance of $RECIPIENT_ADDRESS should have changed but remained: $BALANCE_ORIG"
fi
echo "Balance of $RECIPIENT_ADDRESS changed from $BALANCE_ORIG to $BALANCE_NEW"

# TODO: check that the staker is making progress after the upgrade
while [ "$NUM_CONFIRMED_NODES_BEFORE_UPGRADE" == "$(cast call --rpc-url $RPC_URL $ROLLUP_ADDRESS 'latestConfirmed()(uint256)')" ]; do
  echo "Waiting for confirmed nodes ..."
  sleep 5
done

echo "Confirmed nodes have progressed"
