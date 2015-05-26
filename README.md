# Provisioning Gluster Volumes for Kubernetes

The *newvol.sh* script performs the following:

* optionally creates a new gluster volume if the supplied volume does not exist
in the trusted storage pool,
* if the volume is new:
 * ensures that the underlying bricks are mounted on an xfs file system,
 * creates and starts a new gluster volume,
* creates an endpoints  yaml file representing the glusterfs storage nodes,
* creates a persistent volume yaml file representing the new storage capacity,
* executes kubectl to make the new storage visible to kubernetes.

## Usage:

```
 newvol.sh [--replica <r>] [--kube-master <node> ] [--volname <vname>] \
           --size <n>  <nodeSpec | storage-node>

```
  arg | meaning and default
  :-: | ------------------
  r | replica count for each volume, default=2.
  node | name of kube-master node, default is localhost
  vname | volume name, default is a random 16 character name starting with an uppercase letter.
  n | size of volume to be provisioned to kubernetes, eg. 20Gi.
  nodeSpec | list of storage-node:brick-mnt-path:brick-dev-path if *vname* is new. Eg. *"rhs-node-1:/mnt/brick:/dev/vg1/lv1 rhs-node-2:/mnt/brick:/dev/vg1/lv1 ..."*. If *vname* already exists then just a single storage node spanned by *vname* is required.

The file names for the two new yaml files created are the volume name with "-endpoints.yaml" or "-storage.yaml" appended. These files are overwritten if they exist.
