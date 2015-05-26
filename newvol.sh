#!/bin/bash
#
# Optionally creates a new volume in an existing trusted storage pool, and makes
# the passed-in volume available to kubernetes.
#
# TODO:
#

# functions #

# usage: print usage and return.
#
function usage() {

  cat <<EOF

  Usage:
    newvol.sh [--replica <r>] [--kube-master <node> ] [--volname <vname>] \
           --size <n>  <nodeSpec | storage-node>

  where:

    r         : replic count, default=2
    node      : kubernetes master node, default is localhost
    vname     : name of existing or new glusterfs volume
    n         : (required) size to be provisioned to kubernetes persistent
                storage pooli, eg 20Gi.
    nodeSpec  : (required) list of 1 or more storage nodes. If <vname> is new
      or        then this list must contain at list 2 nodes and the brick mount
    storage-    and block device path must be specified per node using ":" as a
     node       separator, eg. "node1:/mnt/brick:/dev/VG1/LV1". The brick and
                block dev names do not need to be repeated for subsequent nodes
                if same names are used on each node in the list. If <vname> 
                exists then only the node name of any storage node spanned by
                the volume is required. The brick and block dev names can be
                omitted and are ignored. Node names are needed to define the
                storage endpoints.
   
EOF
  return 0
}

# help: output simple help text plus usage.
function help() {

  cat <<EOF

  Optionally create a new glusterfs volume spanning the supplied nodes and
  bricks, create yaml files representing the endpoints of the storage nodes,
  create a yaml file representing a new persistent volume to be made available
  to kubernetes, supply these yaml files to kubectl create, and show the 
  resulting status.

EOF

  usage
  return 0
}

# rand_name: outputs a random name of N-1 characters, with the first char being
# a random uppercase letter.
#
function rand_name() {

  local n=$1 # total length of name
  local first; local name

  n=$((n-1)) # since 1st char is always a letter
  first=$(($RANDOM % 26 + 65)) # 65..90

  name=$(printf \\$(printf '%03o' $first)) # poor man's chr()
  name+="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $n | head -n 1)"

  echo "$name"
  return 0
}

# parse_cmd: use get_opt to parse the command line. Returns 1 on errors.
#
function parse_cmd() {

  local long_opts='help,replica:,kube-master:,volname:,size:'
  local first

  eval set -- "$(getopt -o ' ' --long $long_opts -- $@)"

  while true; do
      case "$1" in
        --help)
          help; exit 0
        ;;
        --replica)
          REPLICA_CNT=$2; shift 2; continue
        ;;
        --volname)
          VOLNAME=$2; shift 2; continue
        ;;
        --kube-master)
          KUBE_MSTR=$2; shift 2; continue
        ;;
        --size) # required
          VOLSIZE=$2; shift 2; continue
        ;;
        --)
          shift; break
        ;;
      esac
  done

  NODE_SPEC=($@) # array of node:brick-mnt:blk-dev tuplets

  # check any required args and assign defaults
  [[ -z "$VOLSIZE" ]] && {
    echo "Syntax error: volume size (--size) is required";
    usage;
    return 1; }

  [[ -z "$NODE_SPEC" ]] && {
    echo "Syntax error: node-spec argument is missing";
    usage;
    return 1; }

  if [[ -z "$VOLNAME" ]]; then
    # generate a random volname
    VOLNAME=$(rand_name 16)
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
# Note: both NODE_BRKMNTS and NODE_BLKDEVs can be empty of values. This occurs
#   when only a single storage node is specified, as is the case when the
#   supplied volume already exists.
# The brick mount and block dev values are a lists. Most times the list
# contains only one brick-mnt/block-dev, but to handle the case of the same
# node repeated with different brick-mnt and/or block-dev paths a list is used.
# Returns 1 on errors.
#
function parse_nodes_brkmnts_blkdevs() {

  local node_spec=(${NODE_SPEC[0]//:/ }) # split after subst ":" with space
  local def_brkmnt=${node_spec[1]} # default, may be empty
  local def_blkdev=${node_spec[2]} # default, may be empty
  local brkmnts=(); local blkdev; local brkmnt; local items; local cnt

  # remove trailing / if present in default brkmnt
  def_brkmnt="${def_brkmnt%/}" #note, def_brkmnt may be empty

  # parse out list of nodes, format: "node[:brick-mnt][:blk-dev]"
  for node_spec in ${NODE_SPEC[@]}; do
      node=${node_spec%%:*}
      items=(${node_spec//:/ }) # subst any :s with a space to make an array
      cnt=${#items[@]}; ((cnt--))
      # fill in missing brk-mnts and/or blk-devs
      case $cnt in # num of ":"s
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

# check_ssh: verify that the user can passwordless ssh as root to the passed-in
# list of nodes. Returns 1 on errors.
# Args: $@ = list of nodes.
function check_ssh() {

  local nodes="$@"
  local node; local err; local errcnt=0

  for node in $nodes; do
      ssh -q root@$node exit
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

# nodes_to_ips: set the global NODE_IPS variable which contains the ip address
# for the storage nodes. Typically each node is a hostname rather than an ip
# address. If the passed-in node is already an ip address it is still added to
# the NODE_IPS array.
# Args: $@, list of unique storage node names.
# Assumption: the list of passed-in nodes is *unique*, that way the output has
#   only 1 ip-addr as the value of each node.
#
function nodes_to_ips() {

  local node

  # nested function returns 0/true if the passed-in node appears to be an ipv4
  # address, else returns 1.
  function is_ip_addr() {

    local octet='(25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])' # cannot exceed 255
    local ipv4="^$octet\.$octet\.$octet\.$octet$"

    [[ "$1" =~ $ipv4 ]] && return 0 # true
    return 1 # false
  }

  # nested function to convert the passed-in node to its ip address. If the
  # node is already an ip addr then just output the ip addr. Returns 1 if 
  # getent cannot convert a hostname to an ip and outputs the node in its
  # original host format.
  function hostname_to_ip() {

    local node="$1"
    local ip; local err

    if is_ip_addr $node; then
      echo "$node"
    else
      ip="$(getent hosts $node)" # uses dns or /etc/hosts
      err=$?
      if (( err != 0 )) || [[ -z "$ip" ]]; then
        echo "$node"
      else
        echo "${ip%% *}" # ip addr
      fi
    fi

    (( err != 0 )) && return 1
    return 0
  }

  # main #

  for node in $@; do
     NODE_IPS[$node]="$(hostname_to_ip $node)"
     (( $? != 0 )) && echo "WARN: $node could not be converted to an ip address"
  done

  return 0
}

# vol_exists: invokes gluster vol info to see if the passed in volunme  exists.
# Returns 1 on errors. 
# Args:
#   $1=volume name, $2=any storage node where gluster cli can be run.
#
function vol_exists() {

  local vol="$1"; local node="$2"

  ssh root@$node "gluster volume info $vol >& /dev/null"
  (( $? != 0 )) && return 1 # false

  return 0 # true
}

# find_nodes: output the list of nodes spanned by the passed-in volume.
# Returns 1 on errors. 
# Args:
#   $1=volume name, 2=any storage node where gluster cli can be run.
#
function find_nodes() {

  local vol="$1"; local node="$2"
  local out; local err

  # volume is expected to exist
  out="$(ssh root@$node "gluster volume status $vol \
	| grep -w ^Brick" \
	| cut -d' ' -f2 \
	| cut -d: -f1)
  "
  err=$?

  echo "$out"
  (( err != 0 )) && return 1
  return 0
}

# check_blkdevs: check that the list of block devices are likely to be block
# devices. Returns 1 on errors.
#
function check_blkdevs() {

  local node; local blkdev; local err; local errcnt=0; local out

  echo "--- checking block devices..."

  for node in ${NODES[@]}; do
      out="$(ssh root@$node "
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

  ssh root@$node "
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

  ssh root@$node "
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
  out="$(ssh root@$FIRST_NODE "
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

  out="$(ssh root@$FIRST_NODE "gluster --mode=script volume start $VOLNAME 2>&1")"
  err=$?
  if (( err != 0 )) ; then # either serious error or vol already started
    if ! grep -qs ' already started' <<<$out ; then
      echo "ERROR: $err: gluster vol start $VOLNAME: $out"
      return 1
    fi
  fi
  return 0
}

# make_yaml: write the kubernetes glusterfs endpoints and PersistentVolume yaml
# files.
# Args: $1=prefix used in constructing the yaml file names, typically the
#   volume name.
#
function make_yaml() {

  local prefix="$1"
  YAML_FILES='' # global
  ENDPOINTS_NAME="${VOLNAME,,}-endpoints" # global, down-case volname
  PV_NAME="pv-${VOLNAME,,}" # global, down-case volname

  function make_endpoints_yaml() {

    local f="${prefix}-endpoints.yaml"
    local buf=''; local node

    buf+='kind: Endpoints\n'
    buf+='apiVersion: v1beta3\n'
    buf+='metadata:\n'
    buf+="  name: $ENDPOINTS_NAME\n"
    buf+='subsets:\n'

    for node in ${UNIQ_NODES[@]}; do
       buf+='  -\n'
       buf+='    addresses:\n'
       buf+="    - IP: ${NODE_IPS[$node]}\n"
       buf+='    ports:\n' # port number doesn't matter
       buf+='    - port: 1\n'
       buf+='      protocol: TCP\n'
    done
  
    echo -e -n "$buf" >$f
    YAML_FILES+="$f "
  }

  function make_persistent_storage_yaml() {

    local f="${prefix}-storage.yaml"
    local buf=''

    buf+='kind: PersistentVolume\n'
    buf+='apiVersion: v1beta3\n'
    buf+='metadata:\n'
    buf+="  name: $PV_NAME\n"
    buf+='spec:\n'
    buf+='  capacity:\n'
    buf+="    storage: $VOLSIZE\n"
    buf+='  accessModes:\n'
    buf+='    - ReadWriteOnce\n'
    buf+='  glusterfs:\n'
    buf+="    path: $VOLNAME\n"
    buf+='    readOnly: true\n'
    buf+="    endpoints: $ENDPOINTS_NAME\n"

    echo -e -n "$buf" >$f
    YAML_FILES+="$f "
  }

  # main #
  make_endpoints_yaml "$1"
  make_persistent_storage_yaml "$1"

  return 0
}

# function do_kubectl: execute kubectl to create each of the files in the
# YAML_FILES list. Args: $@=list of yaml files.
#
function do_kubectl() {

  local f; local errcnt=0

  for f in $@; do
     echo "kubectl create -f $f..."
     [[ "$KUBE_MSTR" != "$HOSTNAME" ]] && scp $f root@$KUBE_MSTR:$f
     ssh root@$KUBE_MSTR "
        kubectl create -f $f
        (( \$? != 0 )) && exit 1
        exit 0
     "
     (( $? != 0 )) && ((errcnt++))
  done

  (( errcnt > 0 )) && return 1
  return 0
}

# show_kube_status: show the output from kubectl get endpoints and xxx.
#
function show_kube_status() {

  local err

  echo
  ssh root@$KUBE_MSTR "
     kubectl get endpoints $ENDPOINTS_NAME && \
       kubectl get pv $PV_NAME
  "
  err=$?

  echo
  (( err == 0 )) && echo "Volume \"$VOLNAME\" made available to kubernetes"
  return 0
}


## main ##

declare -A NODE_IPS
declare -A NODE_BRKMNTS
declare -A NODE_BLKDEVS

parse_cmd $@ || exit -1

# extract nodes, brick mnts and blk devs arrays from NODE_SPEC
parse_nodes_brkmnts_blkdevs || exit -1

# use the first storage node for all gluster cli cmds
FIRST_NODE=${NODES[0]}

# check for passwordless ssh connectivity to the first_node
check_ssh $FIRST_NODE || exit 1

# if the volume already exists then discover its nodes, else make sure the
# nodeSpec list was specified correctly
if vol_exists $VOLNAME $FIRST_NODE; then
  VOL_EXISTS=1 #true
  # find all nodes spanned by volume
  NODES=($(find_nodes $VOLNAME $FIRST_NODE))
  (( $? != 0 )) || [[ -z "$NODES" ]] && {
    echo "ERROR: nodes spanned by \"$VOLNAME\" cannot be determined: ${NODES[@]}"; 
    exit 1; }
else
  VOL_EXISTS=0 #false
  # make sure node-spec was fully specified
  [[ -z "$NODE_BRKMNTS" || -z "$NODE_BLKDEVS" ]] && {
    echo "ERROR: volume \"VOLNAME\" is new, therefore its brick mounts and block device paths must be supplied";
    usage;
    exit -1; }
fi
 
# for cases where storage nodes are repeated there is some improved efficiency
# in reducing the nodes to just the unique nodes
UNIQ_NODES=($(uniq_nodes ${NODES[*]}))

# create the NODE_IPS global assoc array, which contains the ip address for all
# nodes provided by the user
nodes_to_ips ${UNIQ_NODES[*]}

# check for passwordless ssh connectivity to nodes
check_ssh ${UNIQ_NODES[*]} $KUBE_MSTR || exit 1

if (( ! VOL_EXISTS)); then
  check_blkdevs || exit 1 # are block devs likely actual block devices?
  setup_nodes   || exit 1 # setup each storage node, eg. mkfs, etc...
  create_vol    || exit 1
  start_vol     || exit 1
fi

# create yaml files (sets global YAML_FILES variable) to make new volume
# known to kubernetes
make_yaml "$VOLNAME"

# execute the kube persistent vol request
do_kubectl $YAML_FILES || exit 1

show_kube_status

exit 0
