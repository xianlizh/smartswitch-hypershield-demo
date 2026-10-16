# Smartswitch Hypershield Demo

This guide walks through a lab deployment of **Cisco Hypershield** in a **leader / follower** topology and onboarding a **Cisco Smart Switch** so that its traffic is enforced by the Hypershield firewall service.

At a high level you will:

1. Plan vSphere resources, IP addresses and DNS records for both clusters.
2. Deploy the bootstrap OVA to create the **installer VM**, from which all later steps are run.
3. Bootstrap the **leader** cluster, deploy Dex (OIDC) for UI login, then install Hypershield on it.
4. Bootstrap the **follower** cluster, register it with the leader using the leader's CA certificates and a one-time password, then install Hypershield on it.
5. Generate tokens on the follower: a Smart Switch token, and optionally an ND token for Nexus Dashboard integration.
6. Configure the Smart Switch, register it with Hypershield using its token, and redirect VRF/VLAN traffic to the DPUs.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Preparation](#preparation)
  - [VMware Resources](#vmware-resources)
  - [IP Address Plan](#ip-address-plan)
  - [DNS Records](#dns-records)
- [Deploy the Bootstrap OVA](#deploy-the-bootstrap-ova)
  - [Working Directories and KUBECONFIG Switching](#working-directories-and-kubeconfig-switching)
- [Deploy the Leader](#deploy-the-leader)
  - [1. Create the Leader Cluster](#1-create-the-leader-cluster)
  - [2. Deploy Dex (OIDC)](#2-deploy-dex-oidc)
  - [3. Install Hypershield on the Leader](#3-install-hypershield-on-the-leader)
  - [4. Verify the Leader](#4-verify-the-leader)
- [Deploy the Follower](#deploy-the-follower)
  - [1. Create the Follower Cluster](#1-create-the-follower-cluster)
  - [2. Export the Leader's CA Certificates](#2-export-the-leaders-ca-certificates)
  - [3. Register the Follower on the Leader](#3-register-the-follower-on-the-leader)
  - [4. Install Hypershield on the Follower](#4-install-hypershield-on-the-follower)
  - [5. Verify the Follower](#5-verify-the-follower)
  - [6. Generate Tokens](#6-generate-tokens)
- [Smart Switch Onboarding](#smart-switch-onboarding)
  - [1. Base Switch Configuration](#1-base-switch-configuration)
  - [2. Register the Switch](#2-register-the-switch)
  - [3. Redirect Traffic to the DPUs](#3-redirect-traffic-to-the-dpus)
  - [4. Verify the Switch](#4-verify-the-switch)

---

## Prerequisites

- vCenter 8.0 Update 3 or later.
- ESXi hosts with sufficient resources (see [VMware Resources](#vmware-resources)).
- An NTP server reachable from the installer VM and both clusters.
- A DNS server you can edit (see [DNS Records](#dns-records)).
- The bootstrap OVA, downloaded from the Cisco Software Download site:
  1. Go to the Hypershield Bootstrap OVA download page and log in with your Cisco.com credentials.
  2. Download the latest `hypershield-bootstrap-*.ova` file.

---

## Preparation

### VMware Resources

The table below assumes `mgmtCluster.vmProfile: hypershield`, one leader cluster and one follower cluster, each with one control-plane node and one worker node.

| Scope | VMs | Allocated vCPU | Allocated memory | Recommended datastore capacity |
|-------|-----|----------------|------------------|--------------------------------|
| Leader management cluster: 1 control-plane + 1 worker | 2 | 24 | 48 GiB | 350 GiB |
| Follower management cluster: 1 control-plane + 1 worker | 2 | 24 | 48 GiB | 350 GiB |
| Shared installer VM | 1 | 4 | 8 GiB | 60 GiB thin-provisioned boot disk |

> Each control-plane node uses 8 vCPU and 16 GiB RAM. Each Hypershield worker uses 16 vCPU and 32 GiB RAM. If you keep separate installer VMs for the leader and follower, add one more VM with 4 vCPU, 8 GiB RAM, a 60 GiB thin-provisioned boot disk, and one primary-network IP address.

> These are minimum allocations for a demo. Production capacity must also account for workload growth, persistent data, failure recovery, and your vSphere resource policy. For details, see [Minimum VMware and IP address capacity](https://www.cisco.com/c/dam/en/us/td/docs/security/hypershield/user-documentation/hypershield.html#doc-install-vsphere-satisfy-prerequisites--minimum-vmware-and-ip-address-capacity).

### IP Address Plan

Reserve the addresses below before bootstrapping. Make sure none of them are in use and that they do not overlap with any DHCP range.

**Leader**

| Purpose | Address |
|---------|---------|
| Kubernetes API server (VIP) | 10.75.37.131 |
| Registry (Harbor) | 10.75.37.132 |
| IPAM pool (cluster node VMs) | 10.75.37.133 – 10.75.37.135 |
| Timescape (UI / API / gRPC) | 10.75.37.136 |
| Secure Connector | 10.75.37.137 |

**Follower**

| Purpose | Address |
|---------|---------|
| Kubernetes API server (VIP) | 10.75.37.138 |
| Registry (Harbor) | 10.75.37.139 |
| IPAM pool (cluster node VMs) | 10.75.37.140 – 10.75.37.142 |
| Ingester | 10.75.37.143 |
| CLC | 10.75.37.144 |

These values must match what you put into the `bootstrap.yaml` and `hypershield-install-*.yaml` files.

### DNS Records

Hypershield components reach the leader by hostname, and TLS certificates are issued for these names, so the records must exist **before** installation. In dnsmasq format:

```bash
## Hypershield
address=/secure-connector-leader.lab.cisco/10.75.37.137
address=/timescape-grpc.lab.cisco/10.75.37.136
address=/timescape-api.lab.cisco/10.75.37.136
address=/timescape.lab.cisco/10.75.37.136
address=/dex.lab.cisco/10.75.37.134
```

After editing, restart dnsmasq. Once the installer VM is up (next section), verify from it that every name resolves.

> `dex.lab.cisco` points to an address in the leader's IPAM pool. If Dex ends up exposed on a different address in your environment, check with `kubectl get svc -n dex` after deploying it and update the record accordingly.

---

## Deploy the Bootstrap OVA

Deploy the OVA to vSphere by following [Deploy the bootstrap OVA](https://www.cisco.com/c/dam/en/us/td/docs/security/hypershield/user-documentation/hypershield.html#doc-install-vsphere-deploy-bootstrap-ova--deploy-the-bootstrap-ova) in the Hypershield documentation.

The resulting VM is referred to as the **installer VM** in this guide. All remaining steps are run on the installer VM.

### Working Directories and KUBECONFIG Switching

Keep leader and follower files in separate directories, and use [direnv](https://direnv.net/) so that `KUBECONFIG` automatically switches when you `cd` between them. This avoids the classic mistake of running a command against the wrong cluster.

```bash
mkdir -p ~/hypershield/leader/oidc
mkdir -p ~/hypershield/follower/certs

# Install direnv and hook it into the shell
sudo apt install direnv
echo 'eval "$(direnv hook bash)"' >> ~/.bash_profile && source ~/.bash_profile

# Point each directory at its own kubeconfig
echo 'export KUBECONFIG=/home/iep/hypershield/leader/hs-leader.yaml' > ~/hypershield/leader/.envrc
echo 'export KUBECONFIG=/home/iep/hypershield/follower/hs-follower.yaml' > ~/hypershield/follower/.envrc

# direnv refuses to load a new/changed .envrc until it is explicitly allowed
direnv allow ~/hypershield/leader
direnv allow ~/hypershield/follower
```

> If your terminal opens non-login shells (common on Ubuntu desktops and in tmux), add the hook to `~/.bashrc` instead of / in addition to `~/.bash_profile`.

Quick check:

```bash
cd ~/hypershield/leader   && echo $KUBECONFIG   # -> .../leader/hs-leader.yaml
cd ~/hypershield/follower && echo $KUBECONFIG   # -> .../follower/hs-follower.yaml
```

The kubeconfig files (`hs-leader.yaml`, `hs-follower.yaml`) do not exist yet; they are generated when each cluster is bootstrapped.

---

## Deploy the Leader

> Run every step in this section from `~/hypershield/leader`, so that direnv points `kubectl` at the leader cluster.

### 1. Create the Leader Cluster

```bash
cd ~/hypershield/leader
isoctl bootstrap install -f /home/iep/hypershield/leader/bootstrap.yaml
```

This provisions the VMs on vSphere and installs Kubernetes, Cilium, cert-manager, Harbor and the Cluster API controllers.

When it finishes, confirm the cluster is reachable:

```bash
kubectl get nodes -o wide        # all nodes should be Ready
```

### 2. Deploy Dex (OIDC)

Dex provides OIDC login for the Timescape UI. The setup script creates a static admin user whose password is hashed with `htpasswd`, which is why `apache2-utils` is required.

```bash
sudo apt install apache2-utils

# Proxy for outbound downloads; internal ranges and *.cisco are excluded
export HTTP_PROXY="http://proxy-wsa.esl.cisco.com:80"
export HTTPS_PROXY="$HTTP_PROXY"
export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.cisco,.svc,.cluster.local"

# Values consumed by setup-dex-lab.sh
export TIMESCAPE_UI_HOSTNAME="timescape.lab.cisco"   # where users will open the UI (OIDC redirect target)
export DEX_ISSUER_HOST="dex.lab.cisco"               # Dex issuer hostname
export DEX_ADMIN_EMAIL="admin@lab.cisco"             # login name for the UI

# Read the admin password without echoing it or saving it to shell history
read -rs DEX_ADMIN_PASSWORD
export DEX_ADMIN_PASSWORD

cd oidc                      # created during preparation; setup-dex-lab.sh must already be here
chmod +x setup-dex-lab.sh
./setup-dex-lab.sh

# Remove the plaintext password from the environment once Dex is deployed
unset DEX_ADMIN_PASSWORD
cd ..
```

Verify Dex is running and its discovery endpoint answers:

```bash
kubectl get pods -n dex
curl -k https://dex.lab.cisco/.well-known/openid-configuration
```

> Record the admin password somewhere safe (e.g. a password manager) — you'll need it to log in to the UI.

### 3. Install Hypershield on the Leader

Make sure you are back in `~/hypershield/leader`, then:

```bash
isoctl hypershield install -f hypershield-install-leader.yaml
```

This installs the Hubble Timescape stack (ClickHouse, PostgreSQL via CloudNativePG, server, ingester, UI, public API, Secure Connector server, etc.) into the `hubble-timescape` namespace. The first install can take a while, since databases need to initialize.

### 4. Verify the Leader

Watch the pods until everything settles:

```bash
kubectl get pods -A
# Shortcut: show only pods that are NOT Running/Completed (should print just the header)
kubectl get pods -A | grep -vE 'Running|Completed'
```

A healthy leader looks like this (some restarts during initial startup are normal while dependencies come up):

```bash
iep@bj-hs1:~/hypershield/leader$ kubectl get pods -A
NAMESPACE                   NAME                                                             READY   STATUS      RESTARTS       AGE
capi-system                 capi-controller-manager-64ffd4c66d-f9sq6                         1/1     Running     3 (45h ago)    2d9h
capi-system                 capi-ipam-in-cluster-controller-manager-6449f997fb-p5bgq         1/1     Running     3 (45h ago)    2d9h
capi-system                 capi-kubeadm-bootstrap-controller-manager-86489749d6-mhq8w       1/1     Running     3 (45h ago)    2d9h
capi-system                 capi-kubeadm-control-plane-controller-manager-69ff98497b-ccqvt   1/1     Running     0              2d9h
capi-system                 capv-controller-manager-fd97b7d55-pwmcw                          1/1     Running     3 (45h ago)    2d9h
cert-manager                cert-manager-767885ff64-6lk8r                                    1/1     Running     0              2d9h
cert-manager                cert-manager-cainjector-d8d76db4-f8dnb                           1/1     Running     0              2d9h
cert-manager                cert-manager-webhook-69d8bdfff-jl88k                             1/1     Running     0              2d9h
clickhouse-operator         hs-leader-cho-altinity-clickhouse-operator-67b5f4b6ff-7c5fj      2/2     Running     0              47h
cnpg-system                 hs-leader-cnpg-cloudnative-pg-f585c9765-vgpqw                    1/1     Running     2 (45h ago)    47h
dex                         dex-697cbfbcdf-c6zbd                                             1/1     Running     0              47h
hubble-timescape            chi-hubble-timescape-hubble-data-0-0-0                           1/1     Running     0              46h
hubble-timescape            hubble-timescape-gateway-699fd498dc-4nkcz                        1/1     Running     0              46h
hubble-timescape            hubble-timescape-ingester-699ccdfbbd-l8hv6                       1/1     Running     0              46h
hubble-timescape            hubble-timescape-intent-syncer-6bcb799555-r7rt6                  1/1     Running     7 (46h ago)    46h
hubble-timescape            hubble-timescape-migratepg-ac13d41bfd-qqh7n                      0/1     Completed   0              46h
hubble-timescape            hubble-timescape-pg-1                                            1/1     Running     0              46h
hubble-timescape            hubble-timescape-pg-2                                            1/1     Running     0              46h
hubble-timescape            hubble-timescape-public-api-5cdc7bc4f8-99hgv                     1/1     Running     0              46h
hubble-timescape            hubble-timescape-server-7c9c64bb7-7gzmt                          1/1     Running     7 (46h ago)    46h
hubble-timescape            hubble-timescape-trimmer-29818200-k44ck                          0/1     Completed   0              21m
hubble-timescape            hubble-timescape-ui-f75d8585c-xz2dn                              1/1     Running     0              46h
hubble-timescape            sc-server-55c4f8774b-hn2qb                                       1/1     Running     7 (46h ago)    46h
hubble-timescape            sc-server-migratepg-ce41a2df61-mc6g2                             0/1     Completed   0              46h
isovalent-operator-system   isovalent-operator-controller-manager-9967468bc-78p9b            1/1     Running     3 (45h ago)    2d9h
kube-system                 cilium-7d5wz                                                     1/1     Running     0              2d9h
kube-system                 cilium-c8mtx                                                     1/1     Running     0              2d9h
kube-system                 cilium-node-init-7ztq4                                           1/1     Running     0              2d9h
kube-system                 cilium-node-init-gb9vr                                           1/1     Running     0              2d9h
kube-system                 cilium-operator-6d6979b554-v9l26                                 1/1     Running     3 (45h ago)    2d9h
kube-system                 cilium-operator-6d6979b554-wgbvc                                 1/1     Running     1 (46h ago)    2d9h
kube-system                 coredns-7d764666f9-jd22n                                         1/1     Running     0              2d9h
kube-system                 coredns-7d764666f9-lwrl8                                         1/1     Running     0              2d9h
kube-system                 etcd-hs-leader-infra-lmwzv                                       1/1     Running     0              2d9h
kube-system                 kube-apiserver-hs-leader-infra-lmwzv                             1/1     Running     0              2d9h
kube-system                 kube-controller-manager-hs-leader-infra-lmwzv                    1/1     Running     4 (45h ago)    2d9h
kube-system                 kube-scheduler-hs-leader-infra-lmwzv                             1/1     Running     4 (45h ago)    2d9h
kube-system                 kube-vip-hs-leader-infra-lmwzv                                   1/1     Running     4 (45h ago)    2d9h
kube-system                 vsphere-cpi-2jgtt                                                1/1     Running     6 (45h ago)    2d9h
registry                    hs-leader-registry-harbor-core-7d9f77b5b6-bxdrx                  1/1     Running     1 (2d9h ago)   2d9h
registry                    hs-leader-registry-harbor-database-0                             1/1     Running     0              2d9h
registry                    hs-leader-registry-harbor-jobservice-859c4d9998-6w475            1/1     Running     2 (2d9h ago)   2d9h
registry                    hs-leader-registry-harbor-nginx-bb9898b48-6ntrd                  1/1     Running     0              2d9h
registry                    hs-leader-registry-harbor-portal-7c7cdfb99b-qrf6t                1/1     Running     0              2d9h
registry                    hs-leader-registry-harbor-redis-0                                1/1     Running     0              2d9h
registry                    hs-leader-registry-harbor-registry-7cc56f46cd-vblq5              2/2     Running     0              2d9h
registry                    hs-leader-registry-harbor-trivy-0                                1/1     Running     0              2d9h
vmware-system-csi           vsphere-csi-controller-566cf9fb85-qmdtf                          7/7     Running     1 (46h ago)    2d9h
vmware-system-csi           vsphere-csi-node-fjhd2                                           3/3     Running     3 (2d9h ago)   2d9h
vmware-system-csi           vsphere-csi-node-hssw8                                           3/3     Running     2 (2d9h ago)   2d9h
```

Things to look for:

- Everything in `hubble-timescape` and `dex` is `Running`; `*-migratepg-*` and `*-trimmer-*` pods are jobs and are expected to show `Completed`.
- Services that should be reachable from outside have the expected external IPs:
  ```bash
  kubectl get svc -n hubble-timescape -o wide | grep -E 'LoadBalancer|EXTERNAL'
  ```

Finally, open `https://timescape.lab.cisco` in a browser and log in with `DEX_ADMIN_EMAIL` and the password you set. If the login redirect fails, double-check the `dex.lab.cisco` DNS record and `TIMESCAPE_UI_HOSTNAME`.

---

## Deploy the Follower

> Unless stated otherwise, run every step in this section from `~/hypershield/follower`.

### 1. Create the Follower Cluster

```bash
cd ~/hypershield/follower
isoctl bootstrap install -f /home/iep/hypershield/follower/bootstrap.yaml

kubectl get nodes -o wide        # all nodes should be Ready
```

### 2. Export the Leader's CA Certificates

The follower must trust the leader's TLS endpoints:

- `leader-ca.crt` – CA of the Timescape server (used for the follower → leader Timescape connection).
- `sc-server-ca.crt` – root CA of the Secure Connector server (used by the follower's `sc-client`).

These secrets live on the **leader**, so run the export from the leader directory (direnv switches `KUBECONFIG` for you):

```bash
cd ~/hypershield/leader

kubectl get secret hubble-timescape-server-cert -n hubble-timescape -o jsonpath='{.data.ca\.crt}' | base64 --decode > leader-ca.crt
kubectl get secret sc-server-root-ca-tls        -n hubble-timescape -o jsonpath='{.data.ca\.crt}' | base64 --decode > sc-server-ca.crt

mv leader-ca.crt sc-server-ca.crt ../follower/certs/
cd ~/hypershield/follower
```


### 3. Register the Follower on the Leader

In the leader's UI (`https://timescape.lab.cisco`):

1. Open the **Followers** menu and click **Register follower**.
2. Enter the **Follower name** and click **Save and continue**.
3. The UI displays a one-time password (OTP).

> **Important:** The Follower name must be exactly the same as `clusterName` in `hypershield-install-follower.yaml`.

Save the OTP to `~/hypershield/follower/certs/credential` and restrict its permissions:

```bash
vi ~/hypershield/follower/certs/credential   # paste the OTP
chmod 600 ~/hypershield/follower/certs/credential
```

> The OTP can only be used once. If the follower install fails after the join attempt, generate a new OTP on the leader before retrying.

At this point `~/hypershield/follower/certs/` should contain `leader-ca.crt`, `sc-server-ca.crt` and `credential`. Double-check that the paths referenced in `hypershield-install-follower.yaml` match these files.

### 4. Install Hypershield on the Follower

```bash
isoctl hypershield install -f hypershield-install-follower.yaml
```

### 5. Verify the Follower

```bash
kubectl get pods -A
kubectl get pods -A | grep -vE 'Running|Completed'
```

A healthy follower looks like this:

```
iep@bj-hs1:~/hypershield/follower$ kubectl get pods -A
NAMESPACE                   NAME                                                             READY   STATUS      RESTARTS      AGE
capi-system                 capi-controller-manager-64ffd4c66d-7r2lm                         1/1     Running     3 (45h ago)   47h
capi-system                 capi-ipam-in-cluster-controller-manager-6449f997fb-pmmb5         1/1     Running     3 (45h ago)   47h
capi-system                 capi-kubeadm-bootstrap-controller-manager-86489749d6-kx9gn       1/1     Running     3 (45h ago)   47h
capi-system                 capi-kubeadm-control-plane-controller-manager-69ff98497b-td2rh   1/1     Running     0             47h
capi-system                 capv-controller-manager-fd97b7d55-nnv4n                          1/1     Running     3 (45h ago)   47h
cert-manager                cert-manager-767885ff64-9gfp9                                    1/1     Running     0             47h
cert-manager                cert-manager-cainjector-d8d76db4-bs88x                           1/1     Running     0             47h
cert-manager                cert-manager-webhook-69d8bdfff-lft6k                             1/1     Running     0             47h
clickhouse-operator         hs-follower-cho-altinity-clickhouse-operator-5c47bf4dd-9v4j8     2/2     Running     0             45h
cnpg-system                 hs-follower-cnpg-cloudnative-pg-65bcc48c6b-shlvb                 1/1     Running     1 (45h ago)   45h
hubble-timescape            chi-hubble-timescape-hubble-data-0-0-0                           1/1     Running     0             45h
hubble-timescape            hs-follower-clc-hubble-clc-6c745bb74b-47tm5                      1/1     Running     0             45h
hubble-timescape            hubble-timescape-follower-join-vrf9h                             0/1     Completed   0             45h
hubble-timescape            hubble-timescape-ingester-7999869b45-6d2kv                       1/1     Running     0             45h
hubble-timescape            hubble-timescape-server-8694c895b-xmhrn                          1/1     Running     6 (45h ago)   45h
hubble-timescape            hubble-timescape-trimmer-29818200-6c8tj                          0/1     Completed   0             22m
hubble-timescape            sc-client-745f5497bf-llr5t                                       1/1     Running     0             45h
isovalent-operator-system   isovalent-operator-controller-manager-9967468bc-gjs6h            1/1     Running     3 (45h ago)   47h
kube-system                 cilium-4qcgv                                                     1/1     Running     0             47h
kube-system                 cilium-js2qb                                                     1/1     Running     0             47h
kube-system                 cilium-node-init-56fqn                                           1/1     Running     0             47h
kube-system                 cilium-node-init-5jbsn                                           1/1     Running     0             47h
kube-system                 cilium-operator-59b44bcb5f-br76n                                 1/1     Running     1 (46h ago)   47h
kube-system                 cilium-operator-59b44bcb5f-s4hkw                                 1/1     Running     3 (45h ago)   47h
kube-system                 coredns-7d764666f9-mkjqz                                         1/1     Running     0             47h
kube-system                 coredns-7d764666f9-wzzx8                                         1/1     Running     0             47h
kube-system                 etcd-hs-follower-infra-lq5vd                                     1/1     Running     0             47h
kube-system                 kube-apiserver-hs-follower-infra-lq5vd                           1/1     Running     0             47h
kube-system                 kube-controller-manager-hs-follower-infra-lq5vd                  1/1     Running     3 (45h ago)   47h
kube-system                 kube-scheduler-hs-follower-infra-lq5vd                           1/1     Running     3 (45h ago)   47h
kube-system                 kube-vip-hs-follower-infra-lq5vd                                 1/1     Running     3 (45h ago)   47h
kube-system                 vsphere-cpi-68wrk                                                1/1     Running     6 (45h ago)   47h
registry                    hs-follower-registry-harbor-core-5fcb978bf-vzbc9                 1/1     Running     1 (47h ago)   47h
registry                    hs-follower-registry-harbor-database-0                           1/1     Running     0             47h
registry                    hs-follower-registry-harbor-jobservice-677bb95677-2tq86          1/1     Running     3 (47h ago)   47h
registry                    hs-follower-registry-harbor-nginx-6fcc7b5bb-mcccd                1/1     Running     0             47h
registry                    hs-follower-registry-harbor-portal-766f688d67-cb6r4              1/1     Running     0             47h
registry                    hs-follower-registry-harbor-redis-0                              1/1     Running     0             47h
registry                    hs-follower-registry-harbor-registry-867f6f79cb-hj8dc            2/2     Running     0             47h
registry                    hs-follower-registry-harbor-trivy-0                              1/1     Running     0             47h
vmware-system-csi           vsphere-csi-controller-566cf9fb85-f2fjc                          7/7     Running     1 (46h ago)   47h
vmware-system-csi           vsphere-csi-node-gx4ht                                           3/3     Running     2 (47h ago)   47h
vmware-system-csi           vsphere-csi-node-w7t4t                                           3/3     Running     5 (47h ago)   47h
```

Key indicators that the follower has joined the leader:

- `hubble-timescape-follower-join-*` is `Completed`. If it is stuck or in `Error`, check its logs — the usual causes are a wrong/used OTP, a wrong CA file, or DNS not resolving the leader hostnames:
  ```bash
  kubectl logs -n hubble-timescape job/$(kubectl get jobs -n hubble-timescape -o name | grep follower-join | cut -d/ -f2)
  ```
- `sc-client` is `Running` (Secure Connector tunnel to the leader is up).
- `hs-follower-clc-*` and `hubble-timescape-ingester-*` are `Running`.
- The follower shows up as connected in the leader's UI.

### 6. Generate Tokens

Generate service-account tokens on the follower. They are used by external systems to register with / talk to this cluster:

- `smartswitch-token` – used by the Smart Switch in the [registration step](#2-register-the-switch).
- `nd-token` – (optional) only needed for Nexus Dashboard integration.

```bash
cp ~/hypershield/get-token.sh ~/hypershield/follower/get-token.sh

cd ~/hypershield/follower/
chmod +x get-token.sh
# Arguments: <namespace> <token name> --ca-source secret (read the CA bundle from the cluster secret)
./get-token.sh hypershield smartswitch-token --ca-source secret
./get-token.sh hypershield nd-token --ca-source secret          # optional, for ND integration
```

> Make sure you run this from the follower directory — a token generated on the leader will not work for switch registration. Treat the tokens as secrets.

---

## Smart Switch Onboarding

### 1. Base Switch Configuration

The switch needs three things before it can register: DNS to resolve the Hypershield hostnames, a routable source interface to reach the clusters, and the DPU service feature enabled.

```
! --- DNS: needed to resolve the Hypershield hostnames ---
ip domain-lookup
ip name-server 10.75.37.88

! --- Source interface: a loopback that is routable to the Hypershield clusters ---
interface loopback4
  ip address 10.75.53.162/32
interface Ethernet1/1
  medium p2p
  ip unnumbered loopback4
  no shutdown
ip route 0.0.0.0/0 Ethernet1/1 10.75.53.1

! --- Enable the DPUs and the Hypershield service system ---
feature service-acceleration

service system hypershield
  source-interface loopback4
  service firewall
    in-service
```

Notes:

- `Ethernet1/1` borrows its address from `loopback4` (`ip unnumbered`) on a point-to-point link; the default route sends traffic to the upstream gateway `10.75.53.1`. Adjust interface names and addresses to your topology.
- `source-interface loopback4` tells the Hypershield agent which address to use when talking to the controller.

### 2. Register the Switch

Register using the `smartswitch-token` generated on the follower:

```
pod1_smart_switch1# service system hypershield register <smartswitch_token>
```

After a short while, `show service-acceleration status details` should report `Controller Connection Status: success`.

### 3. Redirect Traffic to the DPUs

Choose which traffic is steered into the DPUs for firewall enforcement. In this example, routed traffic in VRF `bj-red` and bridged traffic in VLAN 150 are redirected; `module-affinity dynamic` lets the switch distribute the flows across the available DPUs.

```
service system hypershield
  service firewall
    vrf bj-red module-affinity dynamic
    vlan id 150 bridged-traffic module-affinity dynamic
    in-service
```

> Once traffic is redirected, it is subject to Hypershield policy. Make sure the intended policy is in place on the leader (or that the default action is what you expect) before redirecting production traffic, otherwise you may lose connectivity in that VRF/VLAN.

### 4. Verify the Switch

Expected healthy state:

```
pod1_smart_switch1# show service-acceleration status details
  Service System: hypershield
    Source Interface: loopback4 (10.75.53.162)
    DPU Load-balance Mode: symmetric-hash
    Agent Status: firewall-ready,redirect-installed
    Agent Health Status: ok
    Controller Connection Status: success
    Agent HA Status: not-initialized
    Services:
      Firewall: in-service

      VRF                              Operational State       Affinity(DPU)
      ======================================================================
      bj-red                           forwarding ready        1-2

      VLAN                             Operational State       Affinity(DPU)
      ======================================================================
      150                              forwarding ready        1-2
```

What each field tells you:

| Field | Expected | Meaning |
|-------|----------|---------|
| Source Interface | `loopback4 (10.75.53.162)` | Interface/address used to reach the controller |
| Agent Status | `firewall-ready,redirect-installed` | Firewall service is up and redirect rules are programmed |
| Agent Health Status | `ok` | Agent is healthy |
| Controller Connection Status | `success` | Switch is registered and connected to Hypershield |
| Agent HA Status | `not-initialized` | Expected in a single-switch setup without HA |
| VRF / VLAN Operational State | `forwarding ready` | Traffic for that VRF/VLAN is being steered to DPUs `1-2` |

Finally, generate some traffic in VRF `bj-red` / VLAN 150 and confirm the flows show up in the Timescape UI.

---
