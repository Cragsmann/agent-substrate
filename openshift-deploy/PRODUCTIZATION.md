# Agent Substrate on OpenShift: path to a supported product

This document describes what it would take to turn Agent Substrate into a stable, supported Red Hat product on OpenShift.

It builds on two sources:

- **Hands-on work.** We installed upstream `v1.0.1` on two OpenShift 5.1 clusters (on GCP and AWS) and ran the demos. We also checked an OpenShift 4.22 cluster, where Substrate cannot run. The steps are in [README.md](README.md).
- **The upstream code.** We read the installer, manifests and components to find what the demos hid.

Status: 2026-11-26. "Upstream" means the open source project `agent-substrate/substrate`. "Downstream" means a Red Hat build of it.

## At a glance

**Substrate already works on OpenShift.** The control plane installed, gVisor sandboxes ran, actors suspended and resumed in 85 to 200 ms, and three AI agents took turns on two worker pods. The egress gateway let the agents' traffic through to `api.anthropic.com`. The calls were rejected because our key belongs to Red Hat's model gateway (MaaS), and the demo only knows the public Anthropic endpoint. We have not yet seen a successful model reply from inside a sandbox. We found no architectural blocker.

**What is missing is the product around it.** To be supportable, Substrate needs:

1. a supported sandbox runtime
2. least-privilege security instead of `privileged` containers
3. an OpenShift Operator instead of a command-line installer
4. Red Hat-built and signed images
5. supported snapshot storage and a supported database
6. disconnected installation, FIPS, monitoring and console integration
7. continuous testing on OpenShift

**The one big decision is the sandbox runtime.** Substrate isolates each actor with gVisor or with microVMs. Red Hat does not ship or support gVisor today. Choosing it means taking on a new runtime. The alternative is to build on OpenShift sandboxed containers (Kata), which Red Hat already supports, but which needs nodes with hardware virtualization.

**Minimum version: OpenShift 5.1 (Kubernetes 1.37).** Substrate uses two Kubernetes APIs, PodCertificateRequest and ClusterTrustBundle, for every component's identity. Both were on by default on our 1.37 clusters and absent on 4.22 (Kubernetes 1.35). On older releases they can only be enabled through the `CustomNoUpgrade` feature set, which blocks upgrades and is unsupported. We did not test that route, and treat older releases as out of scope.

## What the demo had to work around

Getting the demo running took several shortcuts. Each one marks a gap a product must close.

| Shortcut in the demo | Why we needed it | What a product needs |
|---|---|---|
| Installed with the `--kind` profile, meant for laptops | The other profile requires Google Cloud | An OpenShift install profile, delivered by an Operator |
| Gave every service account in two namespaces the `anyuid` permission | Some components insist on a fixed user ID | Remove the fixed IDs upstream, or ship narrow permissions |
| Granted the node agent (atelet) the `privileged` SCC, and ran it with SELinux confinement turned off (`spc_t`) | It runs as root with host directories and four added capabilities, and shares `/var/lib/ate` with workers in other namespaces | A dedicated, minimal permission set plus an SELinux policy module |
| Admitted worker pods with a copy of the `privileged` SCC that forces `spc_t` | gVisor workers run as root with nine added capabilities, a host directory, and no seccomp profile, and remount cgroups | A minimal permission set plus an SELinux policy module |
| Set `ip_unprivileged_port_start=0` on the API server and worker pods | They listen on port 443. The worker has no `NET_BIND_SERVICE` capability and relies on the runtime allowing low ports, which containerd does by default and CRI-O does not. The earlier spike found the API server could not bind 443 even with the capability | Upstream sets the value, or uses a port above 1024. We did not confirm the worker needs it |
| Labeled and granted permissions to each demo namespace by script | Every new worker namespace needs them | The Operator manages this automatically |
| Stored snapshots in rustfs, a single 1 GiB pod with fixed passwords | It was the only storage option without cloud setup | Cloud object storage or OpenShift Data Foundation |
| Ran PostgreSQL from a Docker Hub image, single instance | It is what the installer bundles | A supported PostgreSQL with high availability and backups |
| Served actor images from a plain HTTP registry | atelet pulls actor images itself, not through CRI-O. Its credential support expects a GKE-style kubelet plugin, so on OpenShift it pulls anonymously | atelet uses the cluster's pull secret, mirrors and CAs |
| Built images on a laptop with ko and Podman | Developer tooling | Builds in Red Hat's pipeline (Konflux) |

## Work areas

Each area lists why it matters and what to do.

- **Priority:** P0 blocks a supported release. P1 is needed before general availability. P2 can follow.
- **Effort:** relative, not an estimate. S is days, M is weeks, L is a quarter or more.

### 1. Sandbox runtime (P0, L)

**Why it matters.** The runtime is the security boundary between untrusted actors. Red Hat must be able to build it, patch it and stand behind it.

Today the gVisor binary is downloaded at runtime from a public Google Cloud bucket (`gs://gvisor`). A product cannot depend on that.

**Options.**

1. **Support gVisor.** Build it in Red Hat's pipeline, ship it as a signed artifact, and own its security fixes and its compatibility with each RHCOS kernel. This keeps Substrate's design, but it is a large new support commitment.
2. **Build on OpenShift sandboxed containers (Kata).** Red Hat already supports Kata.
   - **Fit is unproven.** Upstream's microVM option runs its own Cloud Hypervisor with guest files downloaded from GitHub, and depends on that hypervisor's snapshot and restore. Whether Kata's supported stack can provide the same suspend and resume is an open question to evaluate first.
   - **Needs hardware virtualization.** It needs nodes with `/dev/kvm`, which usually means bare metal. None of the cloud VMs we tested had it.
   - **Untested on OpenShift.** We have not run the microVM path there yet, and expect more SELinux work.
3. **Offer both:** gVisor where density matters, microVMs where hardware allows.

**Also resolve.** An earlier spike saw files written inside a gVisor sandbox fail to read back. Our runs did not hit it, but nobody has found the cause. It needs an answer before release.

### 2. Security (P0, M to L)

**Why it matters.** Substrate is built to run untrusted code from many tenants. The demo got there by turning off protections, which is not acceptable in a product.

**What to do.**

- **Ship an SELinux policy module** instead of disabling confinement. It must let workers and atelet share the `/var/lib/ate` host directory across namespaces, and allow the mounts and cgroup changes gVisor makes.
- **Ship minimal SCCs**, one for atelet and one for workers, and drop `privileged`.
  - gVisor workers add nine Linux capabilities, including `SYS_ADMIN` and `NET_ADMIN`, and run with seccomp set to `Unconfined`. MicroVM workers add eleven. Upstream documents why each is needed, so the SCC can allow exactly that set.
  - The AppArmor setting has no effect on RHCOS, which uses SELinux instead.
- **Close the image-policy gap.** atelet downloads actor images itself instead of asking CRI-O. As a result, the cluster's image signature checks, registry mirrors and allowed-registry lists do not apply to actor images. That is both a security and a compliance problem.
- **Support FIPS mode.** Build with Red Hat's FIPS-capable Go toolchain and test on FIPS clusters. This includes the Envoy and Rust parts.
- **Review the threat model for OpenShift.** Upstream has one (`docs/security/threat-model.md`). Check it against the OpenShift setup: root workers with host access under the chosen SELinux policy, multiple tenants, the egress TLS interception CA, and the shared bootstrap admin account the installer warns about.

### 3. Installation and lifecycle (P0, L)

**Why it matters.** OpenShift customers install and upgrade software through Operators. A command-line installer that a user runs from a laptop is not supportable.

**What to do.**

- **Build an OLM Operator.** Its custom resource can reuse the settings format the installer already reads. It installs and keeps in sync the CRDs, control plane, permissions, network policies, namespace labels and runtime configuration.
- **Support upgrades and rollbacks.** Upstream already has a version skew policy. Map it to Operator update channels and test every upgrade, including database migrations.
- **Handle day-two operations:** certificate and signing-key rotation, scaling, and a `must-gather` for support cases.
- **Support disconnected clusters.** Every image and runtime file must be mirrorable, and the cluster-wide proxy must work.
- **Decide which topologies to support:** standard clusters, compact clusters, single-node OpenShift, Hosted Control Planes, ROSA and ARO.
  - Hosted and managed clusters restrict node-level changes such as MachineConfigs, which an SELinux module or kernel settings may need.
  - Single-node clusters have little room for worker pools next to the control plane.
- **Keep the CLI** for developers, published as `oc ate`.

### 4. Builds and supply chain (P0, M)

**Why it matters.** Red Hat products ship Red Hat-built images, with known provenance and timely security fixes.

**What to do.**

- **Rebuild every image on UBI** in Konflux, sign them, publish to `registry.redhat.io`, and attach SBOMs. Today the images use Google distroless, Debian, Alpine, Docker Hub's PostgreSQL and upstream Envoy.
- **Decide on Envoy.** Substrate's gateways run upstream Envoy with a custom Rust dynamic module. Either build and maintain both, or check whether the Envoy that OpenShift Service Mesh supports can load that module. The agentgateway dataplane is a second upstream option to weigh.
- **Define architectures.** Upstream builds for amd64 and arm64. gVisor only supports those two, so other architectures would depend on the microVM path.
- **Set the release model:** how closely to follow upstream releases, how to carry patches, and how to issue security errata.

### 5. Storage and data (P0, M)

**Why it matters.** Snapshots hold each actor's memory and files. Losing them loses customer state.

**What to do.**

- **Support real object storage for snapshots.** The code already supports S3 and Google Cloud Storage. The installer needs to offer S3 directly instead of requiring Google Cloud settings. Integrate OpenShift Data Foundation through object bucket claims, and use short-lived cloud credentials instead of static keys. Remove rustfs.
- **Define snapshot policy:** retention, cleanup, quotas, encryption at rest and sizing. A memory snapshot can approach the actor's memory size, and the demo agents are allowed 2 GiB each, so the demo's 1 GiB store is only a demo size.
- **Use a supported database.** Use a Red Hat PostgreSQL image or a supported operator, or let customers bring their own. Define high availability, backup and restore.
- **Document node disk needs.** Each node keeps images, snapshots and actor data under `/var/lib/ate`.

### 6. Networking (P1, M)

**What to do.**

- **Expose actors outside the cluster** through an OpenShift Route with TLS passthrough, or the Gateway API. The router authenticates clients by mTLS with a pod identity certificate from an allowlist, so TLS must reach it intact. Define how outside users and services get such an identity.
- **Check the egress gateway** works with the cluster-wide proxy, egress firewalls, admin network policies and corporate CAs.
- **Test IPv6 and dual stack.** Upstream supports them on kind, but nobody has tested them on OpenShift.

The existing network policies are ingress-only and applied cleanly on OVN-Kubernetes. We did not test that they block what they should.

### 7. Model access for agents (P1, S to M)

**Why it matters.** Agents are Substrate's main workload, and most of them call a language model. Red Hat customers will often use a model gateway, such as Red Hat MaaS or models served by OpenShift AI, rather than a public API.

**What we saw.** The claude-code-multiplex demo hardcodes `api.anthropic.com` in two places: the egress policy the installer creates, and the endpoint Claude Code uses by default. A gateway key sent there is rejected. Pointing the agents at a gateway takes two changes: set the endpoint (`ANTHROPIC_BASE_URL`) in the template, and allow the gateway's host in each agent's egress policy. The MaaS gateway speaks the Anthropic API, so no code change is needed in the agent.

**What to do.**

- **Make the model endpoint configurable** in demos and documentation, with OpenShift AI and MaaS as documented targets.
- **Keep API keys out of templates.** The demo puts the key in the template's environment. That stores it in Substrate's database and inside every snapshot of the agent's memory. Use Substrate's egress credential injection instead. The agent sends a placeholder, and the egress gateway replaces it with the real key on the way out, so the agent never holds it. This needs an `https` egress rule, where the gateway terminates TLS and the agent trusts the gateway's CA, instead of the TLS passthrough the demo uses today.
- **Write egress policies per model host**, so each agent can reach only the models it is meant to use.

### 8. Identity and access (P1, M)

**What to do.**

- **Decide on component certificates.** Substrate runs its own certificate authority for internal mTLS. Keep it, or integrate with OpenShift's service CA or cert-manager. Either way, document CA rotation.
- **Integrate OpenShift login.** By default every CLI user acts as one shared service account, `ate-client`. The API accepts SPIFFE mTLS and OIDC JWTs. OpenShift's built-in OAuth server issues opaque tokens, not JWTs, so it cannot plug in directly. Options are a cluster configured for external OIDC, which issues JWTs, or adding Kubernetes TokenReview support to the API.
- **Map Substrate's permission model** (atespaces and access policies) to OpenShift projects and roles, so admins manage access in one place.

### 9. Observability and console (P1, M)

**What to do.**

- **Feed OpenShift monitoring.** Send metrics to user workload monitoring or the Cluster Observability Operator, with dashboards. Upstream's SLO guide (`docs/guides/slos-and-alerts.md`) suggests the alerting rules to start from.
- **Send traces** to the Red Hat build of OpenTelemetry and Tempo instead of the bundled Jaeger.
- **Check logs** in OpenShift logging, and drop the Google-specific log fields.
- **Write a must-gather** that collects resources, actor and worker state, and SELinux denials.
- **Add a console plugin.** Actors live in Substrate's database, not as Kubernetes objects, so the OpenShift console cannot show them today. A dynamic plugin can show atespaces, actors, templates, pools and snapshots.

### 10. Testing and certification (P0, M)

**What to do.**

- **Run upstream's end-to-end suites on OpenShift** for every build and every supported OpenShift version. The suites create their own namespaces, which need the same labels and permissions as the demos.
- **Test upgrades** of both OpenShift and Substrate. RHCOS kernel updates can affect gVisor.
- **Run scale and soak tests:** many sandboxes per node, constant suspend and resume, node drains. Upstream notes a kernel table limit at about 1000 sandboxes per node.
- **Certify** the Operator and images, and validate FIPS.

### 11. Documentation and support (P1, M)

**What to do.**

- Write guides for installation (connected and disconnected), configuration, security choices, storage sizing, upgrades, troubleshooting and alert runbooks.
- State the support boundaries: runtimes, node types, cloud providers and versions.
- Train support engineers on actors, snapshots and sandbox debugging.

## Changes to propose upstream

Fixing these upstream keeps the downstream build close to the project.

| # | Change | Effort |
|---|---|---|
| 1 | Let WorkerPools set a security context and kernel settings, or default the port setting | S to M |
| 2 | Remove fixed user and group IDs where the image does not need them | S |
| 3 | Let the installer choose S3 storage without Google Cloud settings | M |
| 4 | Make the Google-specific host mounts in atelet optional | S |
| 5 | Make atelet use the cluster's pull secret, mirrors and CAs, or pull through CRI-O | M to L |
| 6 | Make the runtime download location configurable, so it can be mirrored | M |
| 7 | Show only the demo's own workers in the claude-code-multiplex dashboard (fixed on this branch) | S |
| 8 | Make the claude-code-multiplex model endpoint and allowed hosts configurable, and use credential injection for its key | S |
| 9 | Add an OpenShift test lane to upstream CI | M |

## Suggested phases

| Phase | Goal | Main work |
|---|---|---|
| 0. Decide | Agree on scope | Choose the runtime, supported topologies, user roles and OpenShift versions |
| 1. Developer preview | Safe enough to try | Operator alpha, minimal permissions and SELinux module, UBI images, S3 or ODF snapshots, upstream changes 1 to 4, tests on OpenShift |
| 2. Technology preview | Complete on OpenShift | Disconnected and proxy support, OpenShift login, monitoring, console plugin, upgrade tests, FIPS, microVMs on bare metal if in scope |
| 3. General availability | Fully supported | Certified Operator and images, highly available database, backup and restore, scale results, documentation, support training |

## Risks and open questions

- **Supporting gVisor is a big commitment.** It is a kernel written in user space, and its fixes and RHCOS compatibility would be Red Hat's to own.
- **Hardware virtualization is rare in the cloud.** A microVM-first product mostly needs bare-metal nodes.
- **atelet's image pulls skip cluster policy.** Customers with strict image rules may not accept this until it changes.
- **Workers run as root with host access.** Even with an SELinux module, this needs a security review and sign-off.
- **Upstream moves fast.** Version 1.0 is recent. Decide how far behind upstream the product may lag.
- **Several areas are untested on OpenShift:** the gVisor file issue from the spike, microVMs, IPv6, single-node and hosted clusters, and the end-to-end suites.
