# Agent Substrate on OpenShift: path to a supported product

What it would take to make Agent Substrate a supported Red Hat product on OpenShift.

Sources:

- **Demo installs on OpenShift 5.1.** Upstream `v1.0.1` on three clusters: gVisor on GCP and AWS, and the microVM class on a GCP cluster with nested virtualization. Steps are in [README.md](README.md).
- **The upstream code:** installer, manifests and components of `v1.0.1`.

## At a glance

**Substrate works on OpenShift today.** The control plane installed, actors suspended and resumed in 85 to 200 ms with gVisor and 147.5 ms with microVMs, and three AI agents shared two worker pods. No architectural blocker was found.

**The product around it is missing:**

1. a supported sandbox runtime
2. least-privilege security instead of `privileged` containers
3. an Operator instead of a command-line installer
4. Red Hat-built, signed images
5. supported snapshot storage and database
6. disconnected installs, FIPS, monitoring and console integration
7. continuous testing on OpenShift

**The big decision is the sandbox runtime.** Red Hat does not support gVisor, and the microVM class does not use Red Hat's Kata build. The recommendation is to test Substrate's workers under Kata first (section 1).

**Minimum version: OpenShift 5.1 (Kubernetes 1.37).** Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs. They were on by default on 1.37 and absent on 4.22. Older releases could only enable them through `CustomNoUpgrade`, which blocks upgrades.

## What the demo had to work around

Each shortcut marks a gap a product must close.

| Shortcut | Why | Product needs |
|---|---|---|
| `--kind` install profile | The other profile requires Google Cloud | An Operator |
| `anyuid` for all service accounts in two namespaces | Some components pin a user ID | Unpinned IDs or narrow SCCs |
| `privileged` SCC and `spc_t` for atelet | Root, host directories, four added capabilities | Minimal SCC plus an SELinux module |
| A `privileged` copy that forces `spc_t` for workers | Root, nine added capabilities, a host directory, no seccomp, cgroup remounts | Minimal SCC plus an SELinux module |
| `ip_unprivileged_port_start=0` on API server and workers | They bind port 443, which CRI-O blocks. Confirmed for the API server only | Upstream sets it |
| Namespace labels and SCC bindings by script | Every worker namespace needs them | The Operator does it |
| rustfs for snapshots (1 GiB, fixed passwords) | Only option without cloud setup | Object storage or OpenShift Data Foundation |
| Single PostgreSQL from Docker Hub | The installer bundles it | Supported PostgreSQL with HA and backups |
| Plain HTTP registry for actor images | atelet pulls images itself, anonymously on OpenShift | atelet uses the cluster's pull secret, mirrors and CAs |
| Images built on a laptop | Developer tooling | Konflux builds |
| microVM files staged with a `docker` stand-in and a policy exception | The installer's staging assumes kind | The Operator stages them in-cluster |

## Work areas

Priority: P0 blocks release, P1 is needed for GA, P2 can follow. Effort: S is days, M is weeks, L is a quarter or more.

### 1. Sandbox runtime (P0, L)

The runtime is the boundary between untrusted actors, such as agents running generated code. Without a runtime Red Hat can build and patch, there is no supported product.

**Today.** Substrate starts the sandbox inside the worker pod, not through a RuntimeClass, so CRI-O and OpenShift sandboxed containers are not involved.

- **gVisor** runs on any node, including cloud VMs without KVM (AWS m6i, GCP n1). Red Hat does not support it. `runsc` is downloaded from Google's `gs://gvisor` bucket, but the URL is set in `SandboxConfig`, so a downstream build can host its own copy.
- **microVMs** need `/dev/kvm`: bare metal, or nested virtualization, which clouds offer only on some instance types. They use upstream Kata 4.3.1 parts (guest kernel, image, `kata-agent`, `virtiofsd`) on Cloud Hypervisor, driven by Substrate's worker, not Red Hat's Kata build. They ran on GCP nested virtualization, but only under `spc_t`, so the SELinux module must also cover `/dev/kvm` and `virtiofsd`. Bare metal is untested.

**Overlap with Agent Sandbox.** The Red Hat build of Agent Sandbox (OpenShift 5 tech preview) already isolates with Kata. Substrate cannot use it yet: WorkerPools have no `runtimeClassName`.

| Option | What it means | Main risk |
|---|---|---|
| A. Productize gVisor | Build, sign and patch `runsc`; test it on every RHCOS kernel | A new runtime to own |
| B. Kata as the outer boundary | Run worker pods under Kata, gVisor inside optional | Needs `runtimeClassName` and KVM. Host directory, root workers and checkpoints are untested inside Kata |
| C. Red Hat's Kata build in the microVM class | Swap upstream Kata parts for Red Hat's | Red Hat's build must support Cloud Hypervisor snapshot and restore. Needs KVM |
| D. gVisor default, microVMs where KVM exists | A plus the microVM class or C | Two runtimes to own |

**Recommendation.** Spike B first, since it reuses a supported runtime and settles the Agent Sandbox overlap: run a WorkerPool under Kata and check suspend and resume. If it works, Kata is the boundary and gVisor is optional. If not, plan for D and budget for owning gVisor.

**Also resolve** a gVisor file write-then-read failure seen in an earlier spike. Later runs did not hit it, and the cause is unknown.

### 2. Security (P0, M to L)

- **SELinux policy module** instead of `spc_t`. It must allow sharing `/var/lib/ate` across namespaces, gVisor's mounts and cgroup changes, and the microVM devices.
- **Minimal SCCs** for atelet and workers. Upstream documents why each capability is needed (9 for gVisor workers, 11 for microVM). AppArmor settings have no effect on RHCOS.
- **Image policy.** atelet pulls actor images itself, so the cluster's signature checks, mirrors and allowed registries do not apply. This is a security and compliance gap.
- **FIPS** builds with Red Hat's Go toolchain, including the Envoy and Rust parts.
- **Threat model review and security sign-off.** Root workers with host access, multiple tenants, the egress TLS interception CA, and the shared bootstrap admin account.

### 3. Installation and lifecycle (P0, L)

- **An OLM Operator** that installs and reconciles CRDs, control plane, permissions, policies, namespace labels and runtime configuration. It can reuse the installer's settings format.
- **Upgrades and rollbacks** mapped from upstream's version skew policy, including database migrations.
- **Day two:** certificate and key rotation, scaling, `must-gather`.
- **Disconnected clusters:** every image and runtime file mirrorable, cluster-wide proxy supported.
- **Topologies:** decide on compact, single-node, Hosted Control Planes, ROSA and ARO. Only standard clusters are tested. Managed clusters restrict MachineConfigs, which an SELinux module may need.
- **CLI** for developers as `oc ate`.

### 4. Builds and supply chain (P0, M)

- **UBI images** built in Konflux, signed, on `registry.redhat.io`, with SBOMs. Today's bases are distroless, Debian, Alpine and Docker Hub images.
- **Envoy:** the gateways use upstream Envoy plus a custom Rust module. Maintain both, check whether OpenShift Service Mesh's Envoy can load the module, or use the agentgateway dataplane.
- **Architectures:** amd64 and arm64, the only ones gVisor supports.
- **Release model:** how closely to follow upstream, how to carry patches and errata.

### 5. Storage and data (P0, M)

- **Object storage for snapshots.** The code supports S3 and GCS, but the installer requires Google Cloud settings. Use OpenShift Data Foundation or cloud storage with short-lived credentials. Remove rustfs.
- **Snapshot policy:** retention, cleanup, quotas, encryption and sizing. A memory snapshot can approach the actor's memory size.
- **Supported PostgreSQL** with HA, backup and restore, or customer-provided.
- **Node disk sizing** for `/var/lib/ate`.

### 6. Networking (P1, M)

- **External access** through a Route with TLS passthrough or the Gateway API, since the router authenticates clients by mTLS. Define how outside clients get an identity.
- **Egress gateway** with the cluster-wide proxy, egress firewalls and corporate CAs.
- **IPv6 and dual stack** are untested on OpenShift.
- Existing network policies apply on OVN-Kubernetes. Enforcement was not tested.

### 7. Model access for agents (P1, S to M)

Customers will reach models through gateways such as Red Hat MaaS or OpenShift AI, not public APIs.

- **Configurable model endpoint.** The demo hardcodes `api.anthropic.com`, so a MaaS key was rejected. A gateway needs only the endpoint (`ANTHROPIC_BASE_URL`) and an egress rule for its host.
- **No API keys in templates.** A key in the template is stored in Substrate's database and in every memory snapshot. Use egress credential injection, which adds the key at the gateway. It needs an `https` egress rule, not TLS passthrough.
- **Egress policies per model host.**

### 8. Identity and access (P1, M)

- **Component certificates:** keep Substrate's own CA, or use OpenShift's service CA or cert-manager. Document rotation.
- **OpenShift login.** CLI users share one service account by default. The API accepts mTLS and OIDC JWTs, but OpenShift OAuth tokens are not JWTs. Use external OIDC, or add TokenReview support.
- **Permissions:** map atespaces and access policies to OpenShift projects and roles.

### 9. Observability and console (P1, M)

- **Metrics** to OpenShift monitoring, with dashboards and the alerts from upstream's SLO guide.
- **Traces** to Red Hat's OpenTelemetry and Tempo instead of Jaeger.
- **Logs** in OpenShift logging, without the Google-specific fields.
- **must-gather** with actor, worker and SELinux data.
- **Console plugin.** Actors are not Kubernetes objects, so the console cannot show them today.

### 10. Testing and certification (P0, M)

- **Upstream e2e suites on OpenShift** for every build and supported version.
- **Upgrade tests** for OpenShift and Substrate. RHCOS kernel updates can affect gVisor.
- **Scale and soak:** many sandboxes per node (a kernel table limits it near 1000), constant suspend and resume, node drains.
- **Certification** of the Operator and images, and FIPS validation.

### 11. Documentation and support (P1, M)

Guides for install, configuration, security, sizing, upgrades and troubleshooting. Stated support boundaries. Support training on actors, snapshots and sandboxes.

## Changes to propose upstream

Ordered by priority. Downstream-only work, such as the Operator and the SELinux module, is not listed.

| Priority | Change | Why | Effort |
|---|---|---|---|
| P0 | Make atelet's GKE credential settings optional | On non-GKE nodes the default manifest creates an empty config file, and atelet exits | S |
| P0 | Make atelet honor the cluster's pull secret, mirrors, CAs and signature policy, or pull through CRI-O | Actor images bypass cluster image policy and disconnected setups | M to L |
| P0 | Set `ip_unprivileged_port_start` on ate-api-server and worker pods | Port 443 fails on CRI-O. Confirm the worker case first | S |
| P1 | Support SELinux-enforcing nodes without `spc_t` | Consistent labels on shared directories, and documented policy needs | M |
| P1 | Let WorkerPools set a `runtimeClassName` | Needed for Kata (option B) | S |
| P1 | Remove the fixed UID 65532 from atenet and the credential provider | Fixed UIDs force `anyuid`. An earlier lab ran them without it | S |
| P1 | S3 snapshot storage in the installer without Google Cloud settings | The storage plugin already supports S3 | M |
| P1 | TokenReview authentication in ate-api-server | Lets OpenShift users authenticate as themselves | M |
| P1 | OpenShift lane in upstream CI | Catches regressions early | M |
| P2 | microVM file staging outside kind | The installer stages with local docker and for one architecture | S to M |

## Suggested phases

| Phase | Goal | Main work |
|---|---|---|
| 0. Decide | Agree on scope | Runtime, topologies, user roles, OpenShift versions |
| 1. Developer preview | Safe to try | Operator alpha, minimal SCCs and SELinux module, UBI images, S3 or ODF snapshots, P0 upstream changes, OpenShift tests |
| 2. Technology preview | Complete on OpenShift | Disconnected and proxy, OpenShift login, monitoring, console plugin, upgrade tests, FIPS, microVMs on KVM nodes |
| 3. General availability | Fully supported | Certified Operator and images, HA database, backup and restore, scale results, docs, support training |
