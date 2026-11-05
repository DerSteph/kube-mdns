# kube-mdns Helm Chart

Helm chart for deploying [kube-mdns](https://github.com/net-pilgrim/kube-mdns), an automated mDNS (Multicast DNS / Zeroconf / Bonjour) advertiser for Kubernetes Ingresses.

`kube-mdns` watches Kubernetes `Ingress` resources across your cluster and automatically publishes mDNS `.local` hostnames to your local network, enabling seamless resolution without modifying your local DNS server.

---

## Prerequisites

- Kubernetes 1.19+
- Helm 3.8+ (for OCI support)
- A cluster node connected to the physical local network where mDNS broadcasts should be received.

> [!IMPORTANT]
> By default, `kube-mdns` runs with `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`. This is required so mDNS multicast UDP packets (`224.0.0.251:5353`) can travel between the pod and your physical local area network (LAN).

---

## Installing the Chart via OCI (GHCR)

The chart is published as an OCI artifact in GitHub Container Registry (GHCR).

### 1. Install directly

```bash
helm install kube-mdns oci://ghcr.io/net-pilgrim/charts/kube-mdns \
  --namespace kube-mdns-system \
  --create-namespace \
  --version 0.1.0
```

### 2. Or pull and inspect first

```bash
helm pull oci://ghcr.io/net-pilgrim/charts/kube-mdns --version 0.1.0
tar -zxvf kube-mdns-0.1.0.tgz
```

---

## Installing from Source

```bash
git clone https://github.com/net-pilgrim/kube-mdns.git
cd kube-mdns

helm install kube-mdns ./charts/kube-mdns \
  --namespace kube-mdns-system \
  --create-namespace
```

---

## Uninstalling the Chart

```bash
helm uninstall kube-mdns --namespace kube-mdns-system
```

---

## Configuration

The following table lists the configurable parameters of the `kube-mdns` chart and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of pods to run (recommended: 1) | `1` |
| `image.repository` | Image repository | `ghcr.io/net-pilgrim/kube-mdns` |
| `image.tag` | Image tag (defaults to `.Chart.AppVersion`) | `""` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `imagePullSecrets` | Secrets for pulling image from private registries | `[]` |
| `hostNetwork` | Run pod on host network (required for LAN mDNS) | `true` |
| `dnsPolicy` | DNS policy (`ClusterFirstWithHostNet` when hostNetwork) | `ClusterFirstWithHostNet` |
| `strategy.type` | Pod update strategy | `Recreate` |
| `serviceAccount.create` | Create a ServiceAccount | `true` |
| `serviceAccount.automount` | Automount service account token | `true` |
| `serviceAccount.name` | Custom service account name | `""` |
| `rbac.create` | Create ClusterRole & ClusterRoleBinding | `true` |
| `rbac.clusterRoleName` | Custom ClusterRole name | `""` |
| `rbac.extraRules` | Extra RBAC rules to append to ClusterRole | `[]` |
| `kubeMdns.debug` | Run with `--debug` flag | `false` |
| `kubeMdns.logging` | Logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) | `"INFO"` |
| `kubeMdns.interface` | Network interface to bind (e.g. `eth0`) | `""` |
| `kubeMdns.port` | Default fallback port when not found in Ingress | `""` |
| `kubeMdns.serviceType` | Default mDNS service type | `"_http._tcp.local."` |
| `kubeMdns.manualHosts` | List of manual permanent hosts to publish | `[]` |
| `kubeMdns.existingConfigMap` | Use existing ConfigMap for manual config | `""` |
| `kubeMdns.extraArgs` | Extra CLI arguments to pass to `kube-mdns` | `[]` |
| `podSecurityContext` | Pod security context | `runAsNonRoot: true`, `uid: 1000` |
| `securityContext` | Container security context | `readOnlyRootFilesystem: true` |
| `resources` | Resource requests and limits | Limits: 300m/300Mi, Requests: 50m/64Mi |
| `nodeSelector` | Node selector labels | `{}` |
| `tolerations` | Node tolerations | `[]` |
| `affinity` | Pod affinity / anti-affinity | `{}` |

---

## Examples

### 1. Announcing Manual Permanent Hosts

In addition to Ingresses, you can define static hosts in `values.yaml`:

```yaml
kubeMdns:
  manualHosts:
    - hostname: "homeassistant.local"
      ip: "192.168.1.101"
      port: 443
      service_type: "_https._tcp.local."
    - hostname: "nas.local"
      ip: "192.168.1.150"
```

Apply with:
```bash
helm upgrade --install kube-mdns oci://ghcr.io/net-pilgrim/charts/kube-mdns \
  --namespace kube-mdns-system \
  --create-namespace \
  -f custom-values.yaml
```

### 2. Targeting a Specific Host Interface

If the host machine has multiple network interfaces and you want mDNS advertised on a specific adapter (e.g. `eth1` or Multus interface):

```yaml
kubeMdns:
  interface: "eth1"
```

### 3. Pinning to a Specific Node

Since `hostNetwork: true` is enabled, you might want to pin the pod to a node connected directly to your management or home LAN:

```yaml
nodeSelector:
  kubernetes.io/hostname: "k8s-worker-lan-1"
```
