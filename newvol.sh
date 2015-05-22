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
  local first

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

# parse_nodes_brkmnts_blkdevs: set the global NODES array, and the NODE_BRKMNTS
# and NODE_BLKDEVS assoc arrays, based on NODE_SPEC. The format of the assoc
# arrays is:
#   NODE_BRKMNTS[<node>]="<brickmnt>[ <brkmnt1>][ <brmknt2>]..."
#   NODE_BLKDEVS[<node>]="<blkdev>[ <blkdev>][ <blkdev>]..."
# The brick mount and block dev values are a lists. Most times the list
# contains only one brick-mnt/block-dev, but to handle the case of the same
# node repeated with different brick-mnt and/or block-dev paths we use a list.
# Returns 1 on errors.
#
function parse_nodes_brkmnts_blkdevs() {

  local node_spec=(${NODE_SPEC[0]//:/ }) # split after subst ":" with space
  local def_brkmnt=${node_spec[1]} # default
  local def_blkdev=${node_spec[2]} # default
  local brkmnts=(); local blkdev; local brkmnt

  if [[ -z "$def_brkmnt" || -z "$def_blkdev" ]] ; then
    echo "ERROR: expect a brick mount and block device to immediately follow the first node (each separated by a \":\")"
    return 1
  fi

  # remove trailing / if present in default brkmnt
  def_brkmnt="${def_brkmnt%/}"

  # parse out list of nodes, format: "node[:brick-mnt][:blk-dev]"
  for node_spec in ${NODE_SPEC[@]}; do
      node=${node_spec%%:*}
      # fill in missing brk-mnts and/or blk-devs
      case "$(grep -o ':' <<<"$node_spec" | wc -l)" in # num of ":"s
          0) # brkmnt and blkdev omitted
             NODE_BRKMNTS[$node]+="$def_brkmnt "
             NODE_BLKDEVS[$node]+="$def_blkdev "
          ;;
          1) # only brkmnt specified
             brkmnt="${node_spec#*:}"; brkmnt="${brkmnt%/}"; # no trailing /
             NODE_BRKMNTS[$node]+="$brkmnt "
             NODE_BLKDEVS[$node]+="$def_blkdev "
          ;;
          2) # either both brkmnt and blkdev specified, or just blkdev specified
             blkdev="${node_spec##*:}"
             NODE_BLKDEVS[$node]+="${blkdev} "
             brkmnts=(${node_spec//:/ }) # array
             if [[ "${brkmnts[1]}" == "$blkdev" ]] ; then # "::", empty brkmnt
               NODE_BRKMNTS[$node]+="$def_brkmnt "
             else
               brkmnt="${brkmnts[1]}"; brkmnt="${brkmnt%/}"; # no trailing /
               NODE_BRKMNTS[$node]+="$brkmnt "
             fi
          ;;
          *)
             echo "ERROR: improperly specified node-spec list"
             return 1
          ;;
      esac
  done

  # assign unique storage nodes
  NODES=($(printf '%s\n' "${!NODE_BRKMNTS[@]}" | sort))

  return 0
}

## main ##

declare -A NODE_IPS; declare -A NODE_BRKMNTS; declare -A NODE_BLKDEVS

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
