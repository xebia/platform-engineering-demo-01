# Platform Engineering Example — Score on Kubernetes (kind)

A minimal platform-engineering walkthrough: a single Python "Hello, World" web
app described **once** in [Score](https://score.dev) (`score.yaml`), from which we
generate both a Docker Compose file for local development and Kubernetes manifests
for a [kind](https://kind.sigs.k8s.io/) cluster.

> One YAML to rule them all — see https://score.dev/blog/score-one-yaml-to-rule-them-all

## How it works

```
                       ┌──────────────┐
                       │  score.yaml  │   single source of truth
                       └──────┬───────┘
                 score-compose │ score-k8s
                  ┌────────────┴────────────┐
                  ▼                          ▼
          ┌──────────────┐          ┌────────────────┐
          │ compose.yaml │          │ manifests.yaml │
          │ (local dev)  │          │ (Kubernetes)   │
          └──────────────┘          └────────────────┘
```

You only ever edit `score.yaml`. Everything under `dist/` is generated.

## Project structure

```
platform-engineering/
├── Makefile                     # task runner — wraps every command below
├── README.md
├── .gitignore
│
├── workloads/                   # one folder per deployable workload
│   └── hello-world/
│       ├── score.yaml           # the Score spec (source of truth)
│       └── app/                 # this workload's source + how to build it
│           ├── app.py           # Flask: GET / -> "Hello, World!", GET /healthz
│           ├── requirements.txt
│           ├── Dockerfile       # python:3.12-slim, gunicorn on :8080
│           └── .dockerignore
│
├── platform/                    # cluster / infra config (not app code)
│   └── kind/
│       └── cluster.yaml         # kind cluster definition
│
└── dist/                        # generated artifacts (gitignored)
    ├── compose.yaml             # from score-compose
    └── manifests.yaml           # from score-k8s
```

Adding another service is just a new folder under `workloads/`.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- `make`

## 1. Set up Score

Score is two small CLIs — one per target platform. On macOS (Homebrew):

```bash
brew install score-spec/tap/score-compose   # generates Docker Compose
brew install score-spec/tap/score-k8s       # generates Kubernetes manifests
```

Initialise the local state directories (one-time, per project):

```bash
make init
```

This runs `score-compose init` and `score-k8s init`, creating `.score-compose/`
and `.score-k8s/` (gitignored) which hold provisioner config and local state.

## 2. Run locally with Docker Compose

```bash
make up        # generates dist/compose.yaml, then builds + runs
```

Test it:

```bash
curl localhost:8080          # -> Hello, World!
curl localhost:8080/healthz  # -> {"status":"ok"}
```

Stop with `Ctrl-C`, or `make down`.

<details>
<summary>What <code>make up</code> runs under the hood</summary>

```bash
score-compose generate workloads/hello-world/score.yaml \
  --build 'web={"context":"./workloads/hello-world/app"}' \
  --publish '8080:hello-world:8080' \
  -o dist/compose.yaml

docker compose -f dist/compose.yaml --project-directory . up --build
```

`--project-directory .` makes the build context (`./workloads/hello-world/app`)
resolve from the repo root rather than from `dist/`.

`--publish` is required because in Score `service.ports` describes the
*workload-to-workload* service contract, not host publishing — to reach the app
from your laptop you must explicitly publish a host port.
</details>

## 3. Deploy to Kubernetes (kind)

```bash
make deploy    # creates the cluster, builds + loads the image, applies manifests
make forward   # port-forward the workload to localhost:8080
curl localhost:8080
```

<details>
<summary>What <code>make deploy</code> runs under the hood</summary>

```bash
# create cluster (no-op if it already exists)
kind create cluster --config platform/kind/cluster.yaml

# kind has no registry — build the image and load it into the cluster node
docker build -t hello-world-app:0.1.0 ./workloads/hello-world/app
kind load docker-image hello-world-app:0.1.0 --name platform-engineering

# generate + apply
score-k8s generate workloads/hello-world/score.yaml -o dist/manifests.yaml
kubectl apply -f dist/manifests.yaml
kubectl rollout status deploy/hello-world
```

**Image tags & kind:** we use a pinned tag (`hello-world-app:0.1.0`), which gets
`imagePullPolicy: IfNotPresent`, so Kubernetes uses the image loaded into kind.
Avoid `:latest`, which forces `imagePullPolicy: Always` and fails in kind (there
is no registry to pull from).
</details>

Tear down the cluster with `make destroy`.

## Make targets

Run `make help` for the full list. Most-used:

| Target          | Description                                            |
| --------------- | ------------------------------------------------------ |
| `make init`     | Initialise Score local state (one-time)                |
| `make generate` | Generate both `dist/compose.yaml` and `dist/manifests.yaml` |
| `make up`       | Generate + build + run locally via Docker Compose      |
| `make deploy`   | Create cluster + load image + apply manifests          |
| `make forward`  | Port-forward the workload to `localhost:8080`           |
| `make clean`    | Remove generated artifacts (`dist/`)                   |
| `make destroy`  | Delete the kind cluster                                |

## The Score spec (`workloads/hello-world/score.yaml`)

```yaml
apiVersion: score.dev/v1b1

metadata:
  name: hello-world

containers:
  web:
    image: hello-world-app:0.1.0

service:
  ports:
    www:
      port: 8080
      targetPort: 8080
```
