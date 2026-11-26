# Agent Substrate on OpenShift: counter demo

How Agent Substrate v1.0.1 was installed on OpenShift and the counter demo was run end to end, including suspend and resume. Done on 2026-11-26 with Claude Code.

| | |
|---|---|
| Cluster | OCP `5.1.0-0.nightly-2026-11-24-072328`, Kubernetes v1.37.2, GCP, 3 × n1-standard-4 workers (amd64) |
| Substrate | upstream `v1.0.1`, prebuilt images from `ghcr.io/agent-substrate/substrate` |
| Sandbox | gVisor (systrap). microVM not attempted, because the nodes have no `/dev/kvm` |
| Workstation | macOS arm64, Go, `oc`. No Docker, ko or skopeo install needed |

## Result

- **Control plane:** every pod Running: ate-api-server ×2, ate-controller, ate-idp-server ×2, atelet ×3, atenet-router, atenet-egress, k8s-credential-provider, postgres, rustfs, the podcertificate-controller, and the otel collector and jaeger.
- **Counter demo:** the WorkerPool has 3/3 gVisor workers Ready, and the golden snapshot completed.
- **Actor test:** `my-counter-1` counted 1 → 2 → 3 through the router. After `kubectl ate suspend`, the next request resumed it at 4. Memory, file and rootfs counters were all preserved.
- **Restore time:** the worker log reports a total of **204 ms**: sandbox restore 32 ms, app restore 94 ms, wakeup probe 24 ms. The curl times of 1.5–7 s include the `kubectl ate proxy` port-forward from the laptop.
- The gVisor write-then-read failure in the earlier spike ([openshift-challenges.md](https://github.com/pmeida/faas-console-plugin/blob/agent-substrate/docs/research/2026-11-23-agent-substrate-investigation/openshift-challenges.md), challenge 6) did **not** reproduce. Its cause is still unknown.

## Requirements

- **OpenShift on Kubernetes 1.37+ (OCP 5.1+).** Every component gets its mTLS identity from `podCertificate` and `clusterTrustBundle` projected volumes, which need the `ClusterTrustBundle` and `PodCertificateRequest` APIs.
  - 1.37 serves them as GA `certificates.k8s.io/v1`.
  - On OCP 4.x (Kubernetes 1.35) they exist only behind upstream feature gates. Enabling those means `featureSet: CustomNoUpgrade`, which is irreversible and blocks cluster upgrades.
- `cluster-admin` access.
- Go 1.27+ and `oc`, logged in.

## Steps

The scripts are in [scripts/](scripts/), and settings are in [scripts/env.sh](scripts/env.sh). Every script uses the current `oc` context.

```bash
oc login https://api.<cluster>:6443 -u kubeadmin -p '<password>'   # add --insecure-skip-tls-verify on dev clusters
cd openshift-deploy

scripts/00-check-cluster.sh      # needs clustertrustbundles + podcertificaterequests
scripts/01-prepare-worktree.sh   # v1.0.1 worktree, manifests.patch, build ate-setup + kubectl-ate
scripts/02-ocp-prep.sh           # namespaces, PSA labels, SCC grants, ateworker-spc SCC
scripts/03-registry.sh           # plain-HTTP kind-registry in ate-system
scripts/04-deploy-system.sh      # ate-setup --kind deploy ate-system (ghcr v1.0.1 images)
scripts/05-build-counter.sh      # ko build counter → kind-registry, pin demo templates
scripts/06-deploy-counter.sh     # ate-setup deploy demo counter + per-namespace fixes
scripts/07-verify-counter.sh     # create actor, increment, suspend, resume, restore timing
```

To run all of them in one go, stopping at the first failure: `scripts/deploy-all.sh`.

To remove everything: `scripts/99-cleanup.sh`.

### 1. Worktree and manifest patch ([01](scripts/01-prepare-worktree.sh), [manifests.patch](manifests.patch))

`ate-setup` reads manifests from the checkout, so the checkout has to match the image tag. The script fetches upstream `v1.0.1` into a git worktree beside this repo, `../substrate-v1.0.1`, and leaves this checkout alone. It then applies two patches:

| File | Change | Why |
|---|---|---|
| `manifests/ate-install/atelet.yaml` | pod `securityContext.seLinuxOptions.type: spc_t` | RHCOS SELinux denies `container_t` access to the `/var/lib/ate` hostPath that atelet, its objectstore-plugin sidecar and the workers share |
| `manifests/ate-install/ate-api-server.yaml` | pod sysctl `net.ipv4.ip_unprivileged_port_start=0` | On OCP 5.1 binding `:443` fails even with `NET_BIND_SERVICE`. atenet-egress already sets this sysctl upstream |

Patch the files before installing. The installer re-applies manifests, so live `oc patch` edits get reverted.

### 2. Admission: SCCs and Pod Security ([02](scripts/02-ocp-prep.sh))

On OpenShift every pod falls under the `restricted-v2` SCC unless granted more, and Substrate's pods need more:

| Workload | Needs | Grant |
|---|---|---|
| postgres (UID 70), rustfs (10001), envoy/atenet (65532), prometheus (65534) | fixed UIDs | `anyuid` for every SA in `ate-system` and `otel-system` |
| atelet | root, hostPaths, CHOWN/DAC_OVERRIDE/FOWNER/FSETID | `privileged` for SA `atelet` |
| worker pods (`ateworker` SA in each WorkerPool namespace) | root, `/var/lib/ate` hostPath, SYS_ADMIN/NET_ADMIN and more, unconfined seccomp/AppArmor, `spc_t` for the cgroup remount | custom `ateworker-spc`: a copy of `privileged` that forces `seLinuxOptions.type: spc_t` |

The worker SCC has to inject `spc_t` because the WorkerPool template exposes no `securityContext`. Namespaces also need `pod-security.kubernetes.io/enforce=privileged`.

These grants are broad and only suitable for a demo cluster. A supported product would ship narrow SCCs and an SELinux policy module.

### 3. Actor image registry ([03](scripts/03-registry.sh))

atelet pulls actor images itself, anonymously. The `--kind` profile runs atelet with `--localhost-registry-replacement=kind-registry:5000`. With that flag, atelet rewrites any `localhost:*/…` image ref to `kind-registry:5000/…` and pulls it over plain HTTP (`internal/imagecache/imagecache.go`, `parseRef`).

A `registry:3` Deployment and a Service named `kind-registry` in `ate-system` therefore work without any CA bundle, `SSL_CERT_FILE` or registry auth. atelet resolves the short name through its namespace's DNS search path.

The earlier spike used an HTTPS registry with a service-CA certificate and patched a CA bundle into atelet and the workers. Neither is needed here.

### 4. Control plane ([04](scripts/04-deploy-system.sh))

```bash
ate-setup --context "$CTX" --kind --rollout-timeout 300s deploy ate-system \
  --sandbox-classes=gvisor --storage-bucket-name=ate-snapshots \
  --image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.1 \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
```

- `--kind` only selects manifests. It brings in rustfs for S3 snapshot storage, the in-cluster otel stack, and no GCS or GKE dependencies. It doesn't check that the cluster is kind.
- Its one preflight check is that `docker info` succeeds. With `--image-repo`, nothing builds with Docker, so when Docker isn't running `env.sh` puts a stub `docker` on PATH for that command only.
- `--sandbox-classes=gvisor` skips microVM asset staging. The nodes have no KVM.
- The default profile isn't usable off GKE. It hardcodes GCS snapshot storage and requires the GCP transfer service account flags.

### 5. Counter image ([05](scripts/05-build-counter.sh))

Demo images aren't published to ghcr, so the counter is built from source:

```bash
oc port-forward -n ate-system svc/kind-registry 5001:5000 &
KO_DOCKER_REPO=localhost:5001 go run github.com/google/ko@v0.18.0 build --platform linux/amd64 -B ./demos/counter
```

The script then edits the demo templates in the worktree to replace the `ko://` refs with digest-pinned images:

- `demos/counter/counter-template.yaml.tmpl`: `image: localhost:5001/counter@sha256:…`. atelet rewrites this to `kind-registry:5000`.
- `demos/counter/counter.yaml.tmpl`: `workerImage: ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.1@sha256:fd0c6a46…`.

With no `ko://` refs left, `ate-setup` has nothing to build.

### 6. Demo deploy ([06](scripts/06-deploy-counter.sh))

`ate-setup deploy demo counter` recreates `ate-demo-counter`, and ate-controller creates the `ateworker` SA in it. While the deploy is running, the script:

1. labels the namespace `privileged` and binds `ateworker-spc` to `ateworker`, as soon as the SA exists
2. patches the controller-made `counter` Deployment with the `ip_unprivileged_port_start=0` sysctl, because workers listen on `:443`

Then it waits for the golden snapshot.

Two caveats: I didn't test whether the worker sysctl is strictly needed, and ate-controller may revert the patch on a later reconcile.

### 7. Verify ([07](scripts/07-verify-counter.sh))

```bash
kubectl ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl ate proxy actor my-counter-1 -a ate-demo-counter        # localhost:8000
curl -X POST http://localhost:8000/                             # 1, 2, 3
kubectl ate suspend actor my-counter-1 -a ate-demo-counter
curl -X POST http://localhost:8000/                             # 4 → state survived the snapshot
```

The template sets no idle timeout, so the actor doesn't suspend on its own. Suspend it explicitly as above.

### 8. Optional: claude-code-multiplex demo ([08](scripts/08-claude-multiplex.sh))

Three Claude Code agents share a two-pod WorkerPool. A local dashboard resumes an agent when it gets a task and suspends it when the task ends. The agents reach `api.anthropic.com` through `atenet-egress` under a per-actor egress policy.

```bash
export ANTHROPIC_API_KEY=...        # in your shell; the deploy writes it into the actor templates
scripts/08-claude-multiplex.sh    # deploys, then opens the dashboard on the first free port from 8091
```

The installer builds the agent image with `docker buildx`. With only podman installed, [scripts/podman-docker/docker](scripts/podman-docker/docker) stands in for it:

- It runs `podman build` for linux/amd64.
- On macOS, podman builds inside its VM, which can't reach the `localhost:5001` port-forward. So the wrapper saves the image and pushes it from the host with `crane`.
- It then writes the digest file that buildx would have written.

## What changes on the cluster

- Namespaces `ate-system`, `otel-system`, `podcertificate-controller-system` and `ate-demo-counter`, labeled for the privileged Pod Security level.
- ClusterRoleBinding `system:openshift:scc:anyuid` for the groups `system:serviceaccounts:ate-system` and `system:serviceaccounts:otel-system`.
- `privileged` granted to `ate-system/atelet`. SCC `ateworker-spc`, bound to `ate-demo-counter/ateworker`.
- `kind-registry` Deployment and Service.
- Everything `ate-setup deploy ate-system` installs: CRDs, cluster RBAC, the components above.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `certificates.k8s.io` lacks `clustertrustbundles` | The cluster is older than Kubernetes 1.37. Use OCP 5.1+ |
| Pods rejected with `unable to validate against any security context constraint` | Run `02-ocp-prep.sh`. For a new WorkerPool namespace, label it and bind `ateworker-spc` as `06` does |
| ate-api-server `bind: permission denied` on :443 | `manifests.patch` not applied before deploy |
| atelet `permission denied` under `/var/lib/ate` (AVC in `ausearch -m avc`) | atelet isn't running as `spc_t`. Check `manifests.patch` |
| `cannot access Docker` from ate-setup | Run it through the `ate_setup` helper in `env.sh`, which adds the stub |
| Demo deploy times out while workers restart | Re-run `06`. The deploy is idempotent |

## Prompts used

These are the prompts given to Claude Code (Opus 5.5) in this session, in order, with the password redacted. Each is followed by what it led to.

1. > i would like to do a full compatibility analysis of whats needed to run this on openshift can you start the project with demo and run this on this cluster oc login https://api.rluby-dev.pixaa-dev.devcluster.openshift.com:6443 -u kubeadmin -p

   That cluster was OCP 4.22 (Kubernetes 1.35) on AWS. It lacked the certificate APIs, and enabling them needs CustomNoUpgrade. The user chose **analysis only**, and a static compatibility audit was produced.

2. > wht is SCC

   Explained OpenShift SecurityContextConstraints.

3. > lets try here oc login https://api.chat-bot-cvz95-voiox2.openshift-crt-mce.gcp.devcluster.openshift.com:6443 --username kubeadmin --password `<redacted>` and iuse this document to help with deployment of substarte https://github.com/pmeida/faas-console-plugin/blob/agent-substrate/docs/research/2026-11-23-agent-substrate-investigation/openshift-challenges.md

   OCP 5.1 with Kubernetes 1.37 had the APIs. Claude followed that doc and its [runbook](https://github.com/pmeida/faas-console-plugin/blob/agent-substrate/docs/research/2026-11-23-agent-substrate-investigation/openshift-counter-demo-runbook.md), and worked out the `kind-registry` shortcut.

4. > done

   The user ran the SCC prep (`02`) themselves, because Claude Code's auto mode blocks permission grants. Claude then deployed the registry (`03`).

5. > done

   The user ran the control plane install (`04`), which auto mode also blocked. Claude built and pinned the counter image (`05`).

6. > done

   The user ran the demo deploy (`06`). Claude verified the actor, suspend and resume, and restore timing (`07`).

7. > can you write evrything how you did it in doc here with scripts and propmts

   This document.

To run it again with an agent, a prompt like this works:

> Log in to `<cluster>` and deploy Agent Substrate v1.0.1 with the counter demo using `openshift-deploy/`: run scripts 00 through 07 in order, stop on the first failure, and report the restore timing from 07.

Auto mode classifies scripts `02`, `04` and `06` as permission grants, because they bind SCCs and install cluster RBAC. Run those yourself, or allow them in your Claude Code settings.

## Open items

- The gVisor file I/O failure from the earlier spike: it didn't happen here, and the cause is still unknown.
- The worker port sysctl and `spc_t` rely on patching a controller-owned Deployment and on SCC defaulting. Upstream would need WorkerPool `securityContext`/sysctl support, or the worker setting them itself.
- microVM needs nodes with `/dev/kvm`, such as GCP nested virtualization or metal instances, and probably more SELinux work for the kvm device plugin socket.
- An S3 or GCS snapshot backend instead of rustfs. The default profile's GCS path assumes GKE workload identity.
