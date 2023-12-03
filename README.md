# kube-mdns

## Overview
This Python program, deployed as a container in Kubernetes, enables the automatic publishing of mDNS (Multicast DNS) records based on Ingress resources within your local network without manipulating your local DNS Server. It automatically checks for changes in your ingresses and will add / remove mDNS records.

## (Current) Limitations
The program is currently at an early stage. Don't expect too much, currently it works for my needs in my local setup, but I will try to implement some of the still missing features.

- [x] ~~Gets only one load balancer IP for mDNS publishing~~ Implemented with `feature-1`
- [ ] Only works for .local top level domain
- [ ] No configuration through annotations or additional parameters when starting the Python script
- [ ] Uses only port 80
- [ ] No configuration for predefining mDNS entries in your network
- [ ] Currently only works with a pod, no database in the background

## How to use
If you want to have an mDNS record for one of your ingresses, you just need to add ".local" to the host of the ingress rule set.

![Example Ingress Yaml](https://imgur.com/kTKdoyl.jpg)

After applying, the pod should be able to recognize the change and will publishing the address 

![Example Log of kube-mdns](https://imgur.com/AssZkf0.jpg)
## How to install
Before you can run kube-mdns, first you need to add a ClusterRole, a ClusterRoleBinding and a ServiceAccount, wihch gives kube-dns the sufficient permissions to access the kubernetes events.

```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-mdns-clusterrole
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-mdns-clusterrolebinding
subjects:
- kind: ServiceAccount
  name: kube-mdns-service-account
  namespace: default
roleRef:
  kind: ClusterRole
  name: kube-mdns-clusterrole
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-mdns-service-account
```

After this, you can deploy kube-mdns in your Kubernetes environment.

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-mdns
  labels:
    app: kube-mdns
spec:
  selector:
    matchLabels:
      app: kube-mdns
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: kube-mdns
    spec:
      serviceAccountName: kube-mdns-service-account
      hostNetwork: true
      containers:
        - image: ghcr.io/dersteph/kube-mdns:latest
          name: kube-mdns
          imagePullPolicy: Always
      restartPolicy: Always
```