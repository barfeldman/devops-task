# Project overview and build log

This document explains the whole project end to end: what it is, how the pieces
fit together, and the order I built and proved them in. The [README](../README.md)
is the short "what it is and how to run it" version. This file is the longer
story, including the decisions and the problems I hit along the way.

The repo is at [github.com/barfeldman/devops-task](https://github.com/barfeldman/devops-task)
and everything described here is live on a local minikube cluster.

---

## 1. What the project is

I forked a small Node.js sample app and took it all the way to a running,
GitOps-managed deployment with a security-gated CI/CD pipeline. The brief was a
DevOps/DevSecOps exercise, so a working start command was not the goal. It had to
build, test, scan, ship, and roll back the way a real service does.

The finished system does this:

1. I push code to GitHub.
2. Jenkins runs a pipeline of gates (tests, secret scan, SAST, dependency audit,
   Dockerfile lint, manifest scan, image build, image scan) and only a clean
   build is allowed through.
3. Jenkins builds the image, scans it, pushes it to Docker Hub under an immutable
   tag, and writes that tag back into the Helm chart.
4. Argo CD sees the new commit and reconciles the cluster to match it.
5. The app runs behind an nginx ingress, pulls its secret from HashiCorp Vault,
   and exposes Prometheus metrics.
6. If a release is bad, a `git revert` rolls the cluster back to the previous
   immutable image.

---

## 2. The app

It is a tiny Express server on port 8080. The routes:

| Route | Purpose |
| --- | --- |
| `/my-app` | returns `Hello, World!` and increments a Prometheus counter |
| `/about` | a one-line description |
| `/ready` | readiness probe |
| `/live` | liveness probe |
| `/classified` | protected route: 200 with a valid `x-api-token`, 401 without |
| `/metrics` | Prometheus metrics |

The only runtime dependencies are `express` and `prom-client`. There were no
tests in the original, so I added a small smoke test in
[app/test/smoke.js](../app/test/smoke.js) that boots the server and checks the
routes answer. It runs as the first real gate in CI.

The app keeps nothing between requests (the one counter lives in memory and is
scraped by Prometheus), so it is deployed as a Deployment, not a StatefulSet.

---

## 3. The container image

The [Dockerfile](../app/Dockerfile) is multi-stage on `node:22-alpine`:

- A build stage installs dependencies with `npm ci`.
- The runtime stage copies only what it needs, runs `apk --no-cache upgrade`, and
  removes npm's own bundled modules from the base image (those carried CVEs the
  app never uses).
- It runs as a numeric non-root user (`USER 1000`), and the health check uses the
  exec form so it does not spawn a shell.

Those last details were not cosmetic. They are what makes the image pass hadolint
and come back clean from a Trivy image scan.

---

## 4. The Helm chart

The chart lives in [charts/sample-nodejs](../charts/sample-nodejs) and is where
the runtime hardening and the deployment shape are defined:

- **Deployment** with two replicas, a non-root pod security context (read-only
  root filesystem, all capabilities dropped, `RuntimeDefault` seccomp, no service
  account token mounted since the app never calls the Kubernetes API).
- **Service** (ClusterIP) and **Ingress** (nginx, host `sample-nodejs.local`).
- **ConfigMap** for non-secret config.
- **Secret** template that is only rendered when Vault is not in use, so the two
  approaches never collide.
- **ServiceAccount**, **HPA**, and a **helm test** pod that curls `/ready`.
- **Vault custom resources** (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`)
  rendered when `vault.enabled` is set.

The image repository and the deployed tag are chart values. That single fact is
what makes promotion and rollback simple, because the deployed version is just a
line in Git.

---

## 5. The CI/CD pipeline

The [Jenkinsfile](../Jenkinsfile) defines a declarative pipeline that runs on
ephemeral Kubernetes pod agents. Each tool runs in its own container in the agent
pod (node, git, gitleaks, hadolint, helm, kubeconform, semgrep, kaniko, trivy,
skopeo), so there is nothing to install or patch on a static agent and every
build starts clean.

The stages, in order:

| # | Stage | Tool | Gate |
| --- | --- | --- | --- |
| 1 | Checkout | git | computes a short SHA for the tag |
| 2 | Secret Scan | gitleaks | fails on any secret in the git history |
| 3 | Install and Test | node | fails if the app does not boot or a route regresses |
| 4 | SAST | Semgrep | fails on high-severity code findings |
| 5 | Dependency Audit | npm audit | fails on critical dependency vulns |
| 6 | Dockerfile Lint | hadolint | fails on Dockerfile issues |
| 7 | Manifest Scan | Trivy config + kubeconform | fails on HIGH/CRITICAL misconfig or invalid manifests |
| 8 | Version Bump | npm version | computes the immutable `version-sha` tag (main only) |
| 9 | Build Image | Kaniko | rootless build to a local tarball, no push yet |
| 10 | Image Scan | Trivy | fails on HIGH/CRITICAL image CVEs |
| 11 | Push Image | skopeo | pushes to Docker Hub (main only) |
| 12 | Promote | git | writes the new tag into the chart values (main only) |

Two things about the ordering are deliberate. The image is built, scanned, and
only then pushed, so a bad image never reaches the registry. That is why the build
goes to a tarball with Kaniko and gets pushed later with skopeo, rather than both
in one step. The gates also run cheapest and earliest first, so a leaked secret or
a failing test stops the build before it spends time compiling an image.

---

## 6. Secrets with HashiCorp Vault

The app's secret does not live in Git or in a plaintext manifest. The flow:

1. The secret sits in Vault's KV v2 store at `secret/sample-nodejs`.
2. The app's ServiceAccount authenticates to Vault using Kubernetes auth, and a
   least-privilege policy lets that role read only that one path.
3. The Vault Secrets Operator reads it and syncs it into a native Kubernetes
   Secret, which the Deployment consumes with `envFrom`.
4. The app reads `API_TOKEN` and uses it to gate `/classified`. It never logs the
   value.

The Vault path and the auth role are in Git; the secret value never is. The setup
is reproducible from [vault/configure-vault.sh](../vault/configure-vault.sh), and
there is an end-to-end trace in
[docs/proof/vault-secrets.txt](proof/vault-secrets.txt).

---

## 7. GitOps with Argo CD

Argo CD reads the chart straight from this repo
([argocd/application.yaml](../argocd/application.yaml) and
[argocd/project.yaml](../argocd/project.yaml)). It is set to auto-sync, prune, and
self-heal. Promotion is declarative: CI commits a new image tag and Argo brings
the cluster in line with it. There is no manual `helm install` in the deploy path.

For a single service I pointed Argo at the app repo rather than a separate GitOps
repo, so the app, the chart, and the deployed version all move together in one
history. A dedicated environments repo earns its keep once there are several apps,
and the pipeline would barely change if I split it out later.

---

## 8. Images and immutable tags

Images go to Docker Hub at
[docker.io/barfeldman/sample-nodejs](https://hub.docker.com/r/barfeldman/sample-nodejs).
Every image is tagged with the app version plus the short git SHA, for example
`1.0.0-d14da2a`. I do not deploy moving tags like `latest` or a bare `1.0.0`,
because those can point at different bytes tomorrow and make a rollback
meaningless.

The proof of this is that the digest Docker Hub reports for the pushed tag matches
the digest the running pods report pulling, byte for byte
([docs/proof/dockerhub-deploy.txt](proof/dockerhub-deploy.txt)).

---

## 9. Rollback

Because the deployed version is a tag in Git, rolling back is a Git operation:

```bash
git revert <promote-commit>   # put the previous immutable tag back
git push                      # Argo CD reconciles the cluster to it
```

I proved this live rather than just describing it. I promoted a deliberately
broken tag, watched the new pod sit in `ImagePullBackOff` while the old pods kept
serving 200 (the rollout is set so a bad version cannot take the app down), then
reverted the commit and the cluster was healthy again in about six seconds. The
full sequence is in [docs/proof/rollback.txt](proof/rollback.txt). For an incident
there are also lower-level escape hatches (`argocd app rollback`,
`kubectl rollout undo`), but with self-heal on, the durable fix still has to land
in Git.

---

## 10. How I built it, in order

I built it in roughly this order. The commit hashes are in parentheses.

**Scaffold and app (b62e309, adbc6de).** Set up the repo, wrote the multi-stage
Dockerfile, and added the smoke test the original was missing.

**Helm chart (1453ae3).** Wrote the hardened chart: non-root, read-only rootfs,
probes, ingress, and the value-driven image.

**GitOps (07ff4b8).** Added the Argo CD AppProject and Application so the deploy
is declarative from the start.

**CI pipeline (7db541f).** Wrote the first Jenkins pipeline with the core gates
and the build-scan-push ordering.

**Docs and diagram (f16d266, 0de50ad).** Wrote the README with the architecture,
the reasoning, and a run guide, and drew the architecture diagram.

**Deploy and prove (059d0c7).** Stood the whole thing up on minikube and deployed
through Argo CD, not by hand, and captured the evidence.

**Patch real vulns (02aa318).** Running the gates for real surfaced actual
problems: npm audit flagged vulnerable Express transitive deps, and Trivy caught
npm's bundled packages plus an OpenSSL CVE in the base image. That is why the
lockfile is patched and the Dockerfile drops npm and runs `apk upgrade`.

**Run it on real Jenkins (2a377ee).** I deployed Jenkins on the same cluster and
ran the pipeline to make sure it actually works, not just that it compiles. It
went green end to end and shook out two real bugs (a missing timestamper plugin,
and git's dubious-ownership check inside the agent container).

**Vault secrets (e783fe0, 6dfcff6, 08f4512, 71c2fd4).** Integrated Vault and the
Vault Secrets Operator, enabled it for the deployed app through Argo CD,
documented the flow, and captured proof.

**DevSecOps expansion and Docker Hub (d14da2a).** Added the four gates the brief
asked for (gitleaks for secret scanning; hadolint, Trivy config, and kubeconform
for IaC and manifest scanning) and switched the registry from GHCR to Docker Hub.

**Promote the immutable tag (60bdd82).** Built and pushed
`1.0.0-d14da2a` to Docker Hub and pinned it as the deployed version, then verified
the pods pull that exact digest.

**Rollback demo (dddb532, 87f669c).** Promoted a broken tag on purpose and rolled
it back with a `git revert`, capturing the whole thing.

**Fixes and final docs (dc5508d, 30e414f, d5a8e44).** Fixed a Trivy flag, hardened
the helm test pod that a gate correctly flagged, and refreshed the README, the
diagram, and the proof so everything is consistent with the live state.

---

## 11. Problems I hit and how I fixed them

The ones that cost me the most time:

- **npm audit and Trivy found real CVEs.** Fixed by `npm audit fix` (Express to a
  patched version) and by removing npm's bundled modules plus `apk upgrade` in the
  runtime image. Both come back clean now.
- **Jenkins `timestamps()` needed a plugin** that was not installed. Removed it.
- **git "dubious ownership" (exit 128)** inside the agent container. Fixed by
  running the checkout in the git container and marking the workspace a safe
  directory.
- **minikube does not overwrite an existing image tag on load.** When testing
  locally I had to build inside minikube's docker env. This is also why the demo
  now pulls from Docker Hub instead of a local load.
- **Argo CD deploys from `origin/main`.** Local commits do nothing until pushed, so
  a promotion only takes effect after the push.
- **hadolint** flagged a non-numeric user and a shell-form health check. Fixed with
  `USER 1000` and an exec-form `HEALTHCHECK`.
- **Trivy config flagged the helm test pod (KSV0118, a HIGH)** for a default
  security context. The gate was right, so I gave that pod the same non-root,
  read-only, drop-all hardening as the app.
- **`trivy config` rejects `--no-progress`** in the version I used. The correct
  flag is `--quiet`. (`trivy image` still accepts `--no-progress`.)
- **Docker Hub push needed a fresh login.** The push is a credential operation the
  author does; the token never goes through any tooling here.

---

## 12. Current live state

At the time of writing, on minikube:

- Argo CD reports the app **Synced** and **Healthy** on the latest commit.
- Two pods run `docker.io/barfeldman/sample-nodejs:1.0.0-d14da2a`, pulled from
  Docker Hub, with a digest that matches what was pushed.
- Every route answers 200 through the ingress, and `/classified` returns 401
  without the token.
- The `API_TOKEN` in the pod comes from Vault through the Vault Secrets Operator.

A full live dump is in [docs/proof/cluster-state.txt](proof/cluster-state.txt).

---

## 13. Repo layout

```
app/                     Node app, Dockerfile, smoke test
charts/sample-nodejs/    Helm chart (deployment, service, ingress, vault CRs, tests)
argocd/                  Argo CD AppProject and Application
vault/                   reproducible Vault setup script (no secret values)
Jenkinsfile              the CI/CD pipeline
docs/                    architecture diagram, the task, and proof/
docs/proof/              screenshots and text evidence for every claim above
```

### Proof index

| File | Shows |
| --- | --- |
| [cluster-state.txt](proof/cluster-state.txt) | live workload, image digest, Vault CRs, ingress checks |
| [security-scans.txt](proof/security-scans.txt) | the four scan gates passing locally |
| [dockerhub-deploy.txt](proof/dockerhub-deploy.txt) | pushed digest matching the running pods' digest |
| [dockerhub.png](proof/dockerhub.png) | the public Docker Hub repo and tags |
| [rollback.txt](proof/rollback.txt) | bad release, then `git revert` recovery |
| [vault-secrets.txt](proof/vault-secrets.txt) | the Vault to app secret flow |
| [jenkins-build-console.txt](proof/jenkins-build-console.txt) | a real Jenkins run (predates the Docker Hub switch) |
| [argocd-app-tree.png](proof/argocd-app-tree.png) | the Argo CD resource tree including Vault resources |
| [ingress-my-app.png](proof/ingress-my-app.png) | the app served through the ingress |
