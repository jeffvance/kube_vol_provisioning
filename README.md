# Provisioning Red Hat Gluster Storage Volumes for Kubernetes
Kubernetes supports persistent storage via a pool of volumes with defined capacities, and claims against this storage pool. Pods needing persistent storage reference a claim name and are alloted the storage defined by that claim. Neither the claim nor the pod cares about the underlying storage mechanism.

Red Hat Gluster Storage (RHGS) volumes can be used as an underlying storage system. An advantage of using distributed storage in a kubernetes deployment is that all pods can have access to the same storage regardless of which node they are scheduled to run on.

The steps shown in the document describe how to make RHGS storage available to the kubernetes volume pool, how to create a claim against that storage, how to create a pod that uses that storage, and how to test that it is all working correctly. There is also a script, shown in the addendum, that automates the creation of a RHGS volume and assoicated YAML files so that the volume is available to kubernetes.

###Create a Red Hat Gluster Storage Volume
It is assumed that you have a RHGS volume available. If not please follow the steps outlined in the Red Hat Storage Administration Guide, here: https://access.redhat.com/documentation/en-US/Red_Hat_Storage/3/html/Administration_Guide/chap-Red_Hat_Storage_Volumes.html

### Create Endpoints Defining the Volume Topology
Endpoints allow kubernetes to expose various services and to extend its REST API to include non-standard verbs. For RHGS volumes, endpoints define each storage node in the trusted pool. Here is a sample endpoint YAML file:

file: *gluster-endpoints.yaml*
```
kind: Endpoints
apiVersion: v1beta3
metadata:
  name: glusterfs-cluster
subsets:
  -
    addresses:
      - IP: 192.168.122.21 #ip of 1st storage node
    ports:
      - port: 1            #port number is ignored but specified
        protocol: TCP
  -
    addresses:
      - IP: 192.168.122.22 #ip of 2nd storage node
    ports:
      - port: 1
        protocol: TCP
```
The endpoints are created and visible via *kubectl* as follows:
```
kubectl create -f gluster-endoints.yaml

kubectl get endpoints gluster-cluster
NAME                ENDPOINTS
glusterfs-cluster   192.168.122.21:1,192.168.122.22:1
```

###Create a Persistent Volume
For background information on kubernetes persistent volumes and storage claims see: https://github.com/GoogleCloudPlatform/kubernetes/tree/master/examples/persistent-volumes

After you have created a RHGS distributed volume the next step is to make that storage known to kubernetes. The following YAML file defines the RHGS volume:

file: *gluster-pv.yaml*
```
apiVersion: v1beta3
kind: PersistentVolume
metadata:
  name: pv0001
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteMany
  glusterfs:
    path: HadoopVol              #name of a RHGS volume
    endpoints: glusterfs-cluster #name of previously created endpoints
    readOnly: false
```
The persistent volume (pv) is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-pv.yaml 
persistentvolumes/pv0001

kubectl get pv
NAME      LABELS    CAPACITY     ACCESSMODES   STATUS      CLAIM
pv0001    <none>    2147483648   RWX           Available   
```
Note that the size of the PV is 2Gi and the it is shown as "Available". Once a claim against some (or all) of this storage is created the status will change to "Bound".

###Create a Persistent Volume Claim
After you have created a persistent volume the next step is to create a claim against a portion of the persistent volume. The following YAML defines a claim for 1Gi of persistent storage.

file: *glusterfs-claim.yaml*
```
kind: PersistentVolumeClaim
apiVersion: v1beta3
metadata:
  name: myclaim-1
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi  #only 1Gi is being claimed here
```
The persistent volume claim (pvc) is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-claim.yaml 
persistentvolumeclaims/myclaim-1

kubectl get pvc myclaim-1
NAME        LABELS    STATUS    VOLUME
myclaim-1   map[]     Bound     pv0001
```
Note that the size of the PVC is only 1Gi and the status is now shown as "Bound".

###Create a Pod Using RHGS Storage
Once the claim (PVC) is bound to a persistent storage volume (PV) the next step is to create a pod that can access that storage. The YAML file below creates such a pod. It runs a nginx container with a mount defined as  "/usr/share/nginx/html/test". The document root for nginx is typically "/usr/share/nginx/html" so only files in the "test" directory under the document root are accessed from our RHGS volume. The nginx container listens on port 80 and defines a volume mount named "mypd" (my-persistent-disk) which uses the previously created "myclaim-1" claim. 

file: *gluster-pod.yaml*
```
kind: Pod
apiVersion: v1beta3
metadata:
  name: mypod
  labels:
    name: frontendhttp
spec:
  containers:
    - name: myfrontend
      image: fedora/nginx
      ports:
        - containerPort: 80
          name: http-server
      volumeMounts:
      - mountPath: /usr/share/nginx/html/test
        name: mypd
  volumes:
    - name: mypd
      persistentVolumeClaim:
        claimName: myclaim-1

```
The pod is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-pod.yaml 
pods/mypod

kubectl get pod mypod
POD       IP        CONTAINER(S)   IMAGE(S)       HOST      LABELS              STATUS    CREATED     MESSAGE
mypod                                             f21-3/    name=frontendhttp   Pending   5 seconds   
                    myfrontend     fedora/nginx     

```
Note that the pod's status is "Pending" because it takes time for the nginx image to be pulled from the docker registry, afterwich the volume claim will be statisfied by mounting the volume on the node hosting the pod (which is "f21-3", seen above).

After a few minutes we see that the pod's status is "Running".
```
kubectl get pod mypod
POD       IP           CONTAINER(S)   IMAGE(S)       HOST      LABELS              STATUS    CREATED          MESSAGE
mypod     172.17.0.1                                 f21-3/    name=frontendhttp   Running   2 minutes        
                       myfrontend     fedora/nginx                                 Running   About a minute 
```

###Prove it's Working
We will show that the pod created on the node "f21-3" has mounted the RHGS volume and that files existing on that volume are available to the pod.

On the "f21-3" node get the container id using *docker ps*:
```
ssh f21-3

docker ps
CONTAINER ID        IMAGE                                  COMMAND             CREATED             STATUS              PORTS               NAMES
3d3397bf69eb        fedora/nginx:latest                    "/usr/sbin/nginx"   3 minutes ago       Up 3 minutes                            k8s_myfrontend.32ed1327_mypod_default_6cee84e0-0a37-11e5-bb68-5254007d1adf_c524f139   
8cc34564272c        gcr.io/google_containers/pause:0.8.0   "/pause"            3 minutes ago       Up 3 minutes                            k8s_POD.fa30ecd5_mypod_default_6cee84e0-0a37-11e5-bb68-5254007d1adf_bfc1f373    
```
We see that the container id is "3d3397bf69eb". We shell into this container to see the RHGS mount as follows:
```
docker exec -it 3d3397bf69eb /bin/bash
## now we're running bash from within the container

bash-4.3# mount | grep gluster
192.168.122.21:HadoopVol on /usr/share/nginx/html/test type fuse.glusterfs (rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072)

exit
```
Above we see that the RHGS volume made available to the kubernetes persistent volume ("HadoopVol") has been mounted within the container executing inside the pod we created ("mypod"). We also see that "/usr/share/nginx/html/test" is the target of the mount point.

We can access files on the RHGS volume. First, on one of the RHGS storage nodes we see that the volume ("HadoopVol") is mounted on "/mnt/glusterfs/HadoopVol", and we've created a file there named "index.html":
```
ssh rhs-1.vm #192.168.122.21

mount | grep glusterfs
rhs-1.vm:/HadoopVol on /mnt/glusterfs/HadoopVol type fuse.glusterfs (rw,default_permissions,allow_other,max_read=131072)

cat /mnt/glusterfs/HadoopVol/index.html

<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>

```
Next, on the "f21-3" kubernetes node we can also access the same "index.html" file. Note that the IP address for "mypod" is shown to be 172.17.0.1 (see the *kubectl get pod mypod* output above), and that the mount point for the volume is "/usr/share/nginx/html/test".
```
ssh f21-3 #same kubernetes node running the pod
# now shell into the running container (as was also shown above)
docker exec -it 3d3397bf69eb /bin/bash

bash-4.3# cat /usr/share/nginx/html/test/index.html
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>

exit
```
We see the same "index.html" file as seen when we ssh'd to one of the RHGS storage nodes. Also, we can use *curl* to fetch the same file:
```
ssh f21-3 #same kubernetes node running the pod

curl 172.17.0.1:80/test/index.html
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>

```

##Addendum
To help automate the creation of a RHGS volume and the creation of the endpoints and persistent volume (pv) YAML files, a script named *newvol.sh* is provided.

The *newvol.sh* script performs the following:

* optionally creates a new gluster volume if the supplied volume does not exist
in the trusted storage pool,
* if the volume is new:
 * ensures that the underlying bricks are mounted on an xfs file system.
 * creates and starts a new gluster volume.
* creates an endpoints yaml file representing the glusterfs storage nodes. This file is named "*vname*-endpoints.yaml".
* creates a persistent volume (pv) yaml file representing the new storage capacity. This file is named "*vname*-pv.yaml".
* executes kubectl to make the new storage visible to kubernetes.

### Usage:

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

The endpoints yaml file is named "*vname*-endpoints.yaml" and the persistent volume yaml file is named  "*vname*-pv.yaml". So, if the supplied volume name is "MyVol" then the endpoints file will be named "MyVol-endpoints.yaml" and the PV file will be named "MyVol-pv.yaml". These files are overwritten if they already exist.
