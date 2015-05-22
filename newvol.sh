#!/bin/bash
#
# Create a new volume in an existing trusted storage pool and make that volume
# available to kubernetes.
#
# TODO:
#

## main ##

parse_cmd $@ || exit -1

# extract nodes, brick mnts and blk devs arrays from NODE_SPEC
parse_nodes_brkmnts_blkdevs || exit -1

# for cases where storage nodes are repeated there is some improved efficiency
# in reducing the nodes to just the unique nodes
UNIQ_NODES=($(uniq_nodes ${NODES[*]}))

# create the NODE_IPS global assoc array, which contains the ip address for all
# nodes provided by the user
nodes_to_ips ${UNIQ_NODES[*]}

# use the first storage node for all gluster cli cmds
FIRST_NODE=${NODES[0]}

# check for passwordless ssh connectivity to nodes
check_ssh ${UNIQ_NODES[*]} || exit 1


# check that the block devs are (likely to be) block devices
check_blkdevs || exit 1

# setup each storage node, eg. mkfs, etc...
setup_nodes || exit 1

# make sure the volume doesn't already exist
vol_exists $VOLNAME $FIRST_NODE && {
  echo "ERROR: volume \"$VOLNAME\" already exists";
  exit 1; }

# volume name can't conflict with other names under the brick mnts
path_avail || exit 1

# create and start the volume
create_vol || exit 1
start_vol  || exit 1

echo
echo "  Volume \"VOLNAME\" created and made available to kubernetes"
exit 0
