#!/usr/bin/env bash

fail(){
    echo "$*" 1>&2; exit -1;
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
./test-node.bash --simple --init-force --detach

# Start espresso sequencer node
docker compose up espresso-dev-node --detach

# Export environment variables in .env file
. "$TEST_DIR/.env"

# Overwrite the ROLLUP_ADDRESS for this test, it might not be the same as the one in the .env file
ROLLUP_ADDRESS=$(docker compose run --entrypoint sh poster -c "jq -r '.[0].rollup.rollup' /config/deployed_chain_info.json | tail -n 1 | tr -d '\r\n'")

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

echo "Deploying ArbOS action"

#forge script to deploy the Espresso ArbOS upgrade action.
cd $ORBIT_ACTIONS_DIR
forge script --chain $L2_CHAIN_NAME contracts/child-chain/arbos-upgrade/DeployArbOSUpgradeAction.s.sol:DeployArbOSUpgradeAction  --rpc-url $L2_RPC_URL --broadcast -vvvv
ARBOS_UPGRADE_ACTION=$(cat broadcast/DeployArbOSUpgradeAction.s.sol/412346/run-latest.json | jq -r '.transactions[0].contractAddress')
echo "Deployed ArbOSUpgradeAction at $ARBOS_UPGRADE_ACTION"

# TODO: figure out why this upgrade does not do anything
cast send $UPGRADE_EXECUTOR "execute(address, bytes)" $ARBOS_UPGRADE_ACTION $(cast calldata "perform()") --rpc-url $L2_RPC_URL --private-key $PRIVATE_KEY

# TODO: remove manually calling the pre-compile
cast send 0x0000000000000000000000000000000000000070 'scheduleArbOSUpgrade(uint64,uint64)' 35 0 --rpc-url http://localhost:8547 --private-key $PRIVATE_KEY

#check the upgrade happened

ARBOS_VERSION_AFTER_UPGRADE=$(cast call "0x0000000000000000000000000000000000000064" "arbOSVersion()" --rpc-url $L2_RPC_URL --private-key $PRIVATE_KEY)

#The arbsys precompile is returning 55 for the arbos version which indicates that the value internally is 0
if [ $ARBOS_VERSION_AFTER_UPGRADE != "0x0000000000000000000000000000000000000000000000000000000000000090" ]; then
  fail "ArbOS version not updated: Expected 35, Actual $ARBOS_VERSION_AFTER_UPGRADE"
fi

#test for new OSP address
OSP_ADDR=$(cast call $CHALLENGE_MANAGER_ADDRESS $(cast calldata "osp()") --rpc-url $RPC_URL --private-key $PRIVATE_KEY)

if [ $NEW_OSP_ENTRY != $OSP_ADDR ]; then
  fail "OSP has not been set to newly deployed OSP: \n Newly deployed: $NEW_OSP_ENTRY \n Currently set OSP: $OSP_ADDR"
fi
# check for balance update and transactions actually being sequenced
ORIGINAL_OWNER_BALANCE=$(cast balance $OWNER_ADDRESS -e)

docker compose run scripts send-l2 --ethamount 100 --to l2owner --wait

NEW_OWNER_BALANCE=$(cast balance $OWNER_ADDRESS -e)

if [ $(($ORIGINAL_OWNER_BALANCE + 100)) != $NEW_OWNER_BALANCE ]; then
  fail "Owner balance should have increased: Expected amount: $(($ORIGINAL_OWNER_BALANCE + 100)), Actual ammount: $NEW_OWNER_BALANCE"
fi

docker compose run scripts send-l2 --ethamount 100 --to l2owner --wait

FINAL_OWNER_BALANCE=$(cast balance $OWNER_ADDRESS -e)

if [ $(($NEW_OWNER_BALANCE + 100)) != $FINAL_OWNER_BALANCE ]; then
  fail "Owner balance should have increased: Expected amount: $(($ORIGINAL_OWNER_BALANCE + 100)), Actual ammount: $NEW_OWNER_BALANCE"
fi
