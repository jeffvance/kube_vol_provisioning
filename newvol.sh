#!/bin/bash
#
# Create a new volume in an existing trusted storage pool and make that volume
# available to kubernetes.
#
# TODO:
#

# functions #

# parse_cmd: use get_opt to parse the command line. Returns 1 on errors.
#
function parse_cmd() {

  local long_opts='replica:,kube-master:,volname:'
  local rand_cmd; local first

  eval set -- "$(getopt -o ' ' --long $long_opts -- $@)"

  while true; do
      case "$1" in
        --replica)
          REPLICA_CNT=$2; shift 2; continue
        ;;
        --volname)
          VOLNAME=$2; shift 2; continue
        ;;
        --kube-master)
          KUBE_MSTR=$2; shift 2; continue
        ;;
        --)
          shift; break
        ;;
      esac
  done

  NODE_SPEC=($@) # array of node:brick-mnt:blk-dev tuplets

  # check any required args and assign defaults
  [[ -z "$NODE_SPEC" ]] && {
    echo "ERROR: node-spec argument missing";
    return 1; }

  if [[ -z "$VOLNAME" ]]; then
    # generate a random volname, starting with a random uppercase letter
    first=$(($RANDOM % 26 + 65)) # 65..90
    VOLNAME=$(printf \\$(printf '%03o' $first)) # poor man's chr()
    ##rand_cmd="cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 15 | head -n 1"
    VOLNAME+="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 15 | head -n 1)"
    echo "INFO: volume name omitted, using random name \"$VOLNAME\""
  fi

  if [[ -z "$REPLICA_CNT" ]]; then
    REPLICA_CNT=2
    echo "INFO: replica count omitted, using $REPLICA_CNT"
  fi

  if [[ -z "$KUBE_MSTR" ]]; then
    KUBE_MSTR="$HOSTNAME"
    echo "INFO: kube-master omitted, using localhost ($KUBE_MSTR)"
  fi

  return 0
}


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
