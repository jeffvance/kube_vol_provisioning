# Provisioning Gluster Volumes for Kubernetes

The newvol.sh script performs the following:

* ensures that the underlying bricks are mounted on an xfs file system,
* creates and starts a new gluster volume,
* creates an endpoints  yaml file representing the glusterfs storage nodes,
* creates an persistent volume  yaml file representing the new storage capacity,* executes kubectl to make the new storage visible to kubernetes.

## Usage:

```
 newvol.sh [--replica <r>] [--kube-master <node> ] [--volname <name>] \
           --size <n>  <nodeSpecList>

```
  arg | meaning and default
  :-: | ------------------
  r | replica count for each volume, default=2
  node | name of kube-master node, default is localhost
  name | volume name, default is a random name
  n | size of volume to be provisioned to kubernetes
  nodeSpecList | list of node:brick-mnt-path:brick-dev-path ...

The file names for the two new yaml files created are the volume name with "-endpoints.yaml" or "-storage.yaml" appended. These files are quitely overwritten if they exist.
