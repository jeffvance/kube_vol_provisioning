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

# check_ssh: verify that the user can passwordless ssh to the passed-in list of
# nodes. Returns 1 on errors.
# Args: $@ = list of nodes.
function check_ssh() {

  local nodes="$@"
  local node; local err; local errcnt=0

  for node in $nodes; do
      [[ "$node" == "$HOSTNAME" ]] && continue # skip
      ssh -q $node exit
      err=$?
      if (( err != 0 )) ; then
        echo "ERROR: cannot passwordless ssh to node $node"
        ((errcnt++))
      fi
  done

  (( errcnt > 0 )) && return 1
  return 0
}

# uniq_nodes: output the unique nodes from the list of nodes provided.
# $@=list of nodes.
function uniq_nodes() {

  local nodes=($@)
 
  printf '%s\n' "${nodes[@]}" | sort -u
}

# vol_exists: invokes gluster vol info to see if the passed in volunme  exists.
# Returns 1 on errors. 
# Args:
#   $1=volume name,
#   $2=any storage node where gluster cli can be run.
function vol_exists() {

  local vol="$1"; local node="$2"

  ssh $node "gluster volume info $vol >& /dev/null"
  (( $? != 0 )) && return 1 # false

  return 0 # true
}

# check_blkdevs: check that the list of block devices are likely to be block
# devices. Returns 1 on errors.
#
function check_blkdevs() {

  local node; local blkdev; local err; local errcnt=0; local out

  echo "--- checking block devices..."

  for node in ${NODES[@]}; do
      out="$(ssh $node "
          errs=0
          for blkdev in ${NODE_BLKDEVS[$node]}; do
              if [[ ! -e \$blkdev ]] ; then
                echo \"\$blkdev does not exist on $node\"
                ((errs++))
                continue
              fi
              if [[ -b \$blkdev && ! -L \$blkdev ]] ; then
                echo \"\$blkdev on $node must be a logical volume but appears to be a raw block device. Expecting: /dev/VGname/LVname\"
                ((errs++))
                continue
              fi
          done
          (( errs > 0 )) && exit 1 || exit 0
        ")"
      err=$?
      (( err != 0 )) && {
        ((errcnt++));
        echo "ERROR: $out"; }
  done

  echo "--- done checking block devices"
  (( errcnt > 0 )) && return 1
  return 0
}

# check_xfs:
# Args:
#  1=node,
#  2=block device path,
#
function check_xfs() {

  local node="$1"; local blkdev="$2"
  local isize=512

  ssh $node "
     if ! xfs_info $blkdev >& /dev/null ; then
       mkfs -t xfs -i size=$isize -f $blkdev 2>&1
       (( \$? != 0 )) && {
         echo "ERROR $err on $node: mkfs.xfs on $blkdev";
         exit 1; }
     fi
     exit 0
  "

  (( $? != 0 )) && return 1
  return 0
}

# mount_blkdev: create the brick-mnt dir(s) if needed, append the xfs brick
# mount to /etc/fstab, and then mount it. Returns 1 on errors.
# Args:
#  1=node,
#  2=block device path,
#  3=brick mount path
#
function mount_blkdev() {

  local node="$1"; local blkdev="$2"; local brkmnt="$3"
  local mntopts="noatime,inode64"

  ssh $node "
     # create brk-mnt dir
     [[ ! -e $brkmnt ]] && mkdir -p $brkmnt
     # does brk mnt already exist in fstab?
     (grep $brkmnt /etc/fstab \
        | grep -vE '^#|^ *#' \
	| grep xfs) >/dev/null
     if (( \$? != 0 )); then # add to fstab
       echo \"$blkdev $brkmnt xfs $mntopts 0 0\" >>/etc/fstab
     fi
     # is brk mnt currently mounted?
     (grep $brkmnt /proc/mounts \
	| grep xfs) >/dev/null
     if (( \$? != 0 )); then # mount blk dev
       mount $brkmnt 2>&1 # via fstab entry
       (( \$? != 0 )) && {
         echo \"ERROR $err on $node: mount $blkdev as $brkmnt\";
         exit 1; }
     fi
     exit 0
  "

  (( $? != 0 )) && return 1
  return 0
}

# setup_nodes: performs steps on each storage node needed for a gluster volume.
# Returns 1 on errors.
#
function setup_nodes() {

  local err; local errcnt=0
  local node; local brkmnt; local blkdev; local i

  for node in ${NODES[@]}; do
     brkmnts="${NODE_BRKMNTS[$node]}" # 1 or more brk-mnt path(s)
     blkdevs="${NODE_BLKDEVS[$node]}" # 1 or more blk-dev path(s)

     # xfs
     for blkdev in $blkdevs; do # typically just one
        check_xfs $node $blkdev || ((errcnt++))
     done
     (( errcnt > 0 )) && return 1

     # mount blkdev(s)
     for (( i=0; i<${#blkdevs[@]}; i++ )); do # tyically just one
        mount_blkdev $node $blkdevs[$i] brkmnts[$i] || ((errcnt++))
     done
     (( errcnt > 0 )) && return 1
  done

  return 0
}

# create_vol: gluster vol create VOLNAME with the replica count.
#
function create_vol() {

  local bricks=''; local err; local out; local node; local i 
  local mnt; local mnts_per_node
  local mnts=(${BRKMNTS[@]}) # array of all mnts across all nodes
  let mnts_per_node=(${#mnts[@]} / ${#NODES[@]})

  echo "--- creating the new $VOLNAME volume..."

  # define the brick list -- order matters for replica!
  # note: round-robin the mnts so that the original command nodes-spec list
  #   order is preserved
  for (( i=0; i<mnts_per_node; i++ )); do # typically 1 mnt per node
     for node in ${NODES[@]}; do
        mnts=(${BRKMNTS[$node]}) # array, typically 1 mnt entry
        mnt=${mnts[$i]}
        bricks+="$node:$mnt/$VOLNAME "
     done
  done

  # create the gluster volume
  out="$(ssh $FIRST_NODE "
        gluster --mode=script volume create $VOLNAME replica $REPLICA_CNT \
                $bricks 2>&1"
  )"
  err=$?
  (( err != 0 )) && {
    echo  "ERROR: $err: gluster vol create $VOLNAME $bricks: $out";
    return 1; }
 
  echo "--- \"$VOLNAME\" created"
  return 0
}

# start_vol: gluster vol start VOLNAME. Returns 1 on errors.
#
function start_vol() {

  local err; local out

  out="$(ssh $FIRST_NODE "gluster --mode=script volume start $VOLNAME 2>&1")"
  err=$?
  if (( err != 0 )) ; then # either serious error or vol already started
    if ! grep -qs ' already started' <<<$out ; then
      echo "ERROR: $err: gluster vol start $VOLNAME: $out"
      return 1
    fi
  fi
  return 0
}


## main ##

declare -A NODE_BRKMNTS; declare -A NODE_BLKDEVS

parse_cmd $@ || exit -1

# extract nodes, brick mnts and blk devs arrays from NODE_SPEC
parse_nodes_brkmnts_blkdevs || exit -1

# for cases where storage nodes are repeated there is some improved efficiency
# in reducing the nodes to just the unique nodes
UNIQ_NODES=($(uniq_nodes ${NODES[*]}))

# use the first storage node for all gluster cli cmds
FIRST_NODE=${NODES[0]}

# check for passwordless ssh connectivity to nodes
check_ssh ${UNIQ_NODES[*]} $KUBE_MSTR || exit 1

# check that the block devs are (likely to be) block devices
check_blkdevs || exit 1

# make sure the volume doesn't already exist
vol_exists $VOLNAME $FIRST_NODE && {
  echo "ERROR: volume \"$VOLNAME\" already exists";
  exit 1; }

# setup each storage node, eg. mkfs, etc...
setup_nodes || exit 1

# create and start the volume
create_vol || exit 1
start_vol  || exit 1

# create json (or yaml) file to make new volume known to kubernetes

# execute the kube persistent vol request

echo
echo "  Volume \"VOLNAME\" created and made available to kubernetes"
exit 0
