# DevOps / DevSecOps Challenge — Node.js on Kubernetes

Submission for the DevOps/DevSecOps take-home challenge. It vendors the sample
app from [EladAviczer/sample-nodejs](https://github.com/EladAviczer/sample-nodejs),
containerizes it, deploys it to Kubernetes with a Helm chart, and drives the
whole lifecycle through a Jenkins CI/CD pipeline with DevSecOps gates and GitOps
delivery via ArgoCD.

## Repository structure

| Path | Purpose |
| --- | --- |
| `app/` | Vendored Node.js application and its `Dockerfile` |
| `charts/sample-nodejs/` | Helm chart used to deploy the app |
| `Jenkinsfile` | Jenkins CI/CD pipeline (build, scan, push, deploy) |
| `argocd/` | ArgoCD `Application` manifests (GitOps) |
| `docs/` | Task brief and design notes |

## The application

A lightweight Express.js service listening on port `8080` (override with `PORT`).

| Route | Purpose |
| --- | --- |
| `/my-app` | Main page (`Hello, World!`), increments a Prometheus counter |
| `/about` | Static info |
| `/ready` | Readiness probe endpoint |
| `/live` | Liveness probe endpoint |
| `/classified` | Demo endpoint |
| `/metrics` | Prometheus metrics |

Dependencies: `express`, `prom-client`.

## Key decisions

These are documented here and expanded in `docs/` as each piece is implemented.

- **Workload type — `Deployment`:** the app holds no persistent state (no
  volumes, no sticky identity, metrics are in-memory and scrape-based), so a
  stateless, horizontally scalable `Deployment` is the correct fit rather than a
  `StatefulSet`.
- **CI/CD — Jenkins:** declarative `Jenkinsfile` pipeline.
- **GitOps — ArgoCD:** declarative manifests reconciled from Git.

## Status

Work in progress — see the commit history for how each component was added.
