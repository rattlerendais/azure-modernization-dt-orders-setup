# App Scripts

Scripts for deploying, removing, and restarting workshop applications.

## Prerequisites

- Azure CLI authenticated (`az login`)
- kubectl configured for AKS cluster
- Docker and Docker Compose installed (for monolith/services deployments)
- Workshop credentials configured via `provision-scripts/input-credentials.sh`

## Scripts

### Kubernetes Deployments

| Script | Description |
|--------|-------------|
| `deploy-k8-apps.sh` | Deploy all K8s applications (DT Orders, EasyTrade, Travel Advisor) |
| `deploy-easytrade.sh` | Deploy EasyTrade application to `easytrade` namespace |
| `deploy-travel-advisor.sh` | Deploy Travel Advisor to `travel-advisor-azure-openai-sample` namespace |
| `deploy-crashloop-demo.sh` | Deploy crashloop demo for troubleshooting exercises |
| `remove-k8-apps.sh` | Remove all K8s applications |
| `remove-crashloop-demo.sh` | Remove crashloop demo |

### Docker Compose Deployments

| Script | Description |
|--------|-------------|
| `deploy-monolith.sh` | Deploy DT Orders monolith version via Docker Compose |
| `deploy-services.sh` | Deploy DT Orders microservices version via Docker Compose |
| `remove-monolith.sh` | Remove DT Orders monolith |
| `remove-services.sh` | Remove DT Orders microservices |

### Restart Scripts

| Script | Description |
|--------|-------------|
| `restart-k8-apps.sh` | Restart all K8s applications (DT Orders, Travel Advisor) |
| `restart-dtorders.sh` | Restart DT Orders in `staging` namespace |
| `restart-easytrade.sh` | Restart EasyTrade in `easytrade` namespace |
| `restart-traveladvisor.sh` | Restart Travel Advisor |

### Utility Scripts

| Script | Description |
|--------|-------------|
| `enable-easytrade-problems.sh` | Enable problem patterns in EasyTrade for demo purposes |

## Docker Compose Files

| File | Description |
|------|-------------|
| `docker-compose-monolith.yml` | DT Orders monolith configuration |
| `docker-compose-services.yml` | DT Orders microservices configuration |

## Manifests

Kubernetes manifests used by the deploy scripts:

| Manifest | Description |
|----------|-------------|
| `manifests/crashloop-demo.yaml` | Crashloop demo deployment |
| `manifests/traveladvisor-combined.yaml` | Travel Advisor full deployment |
| `manifests/easytrade/` | EasyTrade kustomization |
| `manifests/hipstershop-manifest.yaml` | Hipster Shop deployment (reference) |

### DT Orders Manifests

| Manifest | Description |
|----------|-------------|
| `manifests/frontend.yml` | DT Orders frontend |
| `manifests/catalog-service.yml` | Catalog service |
| `manifests/customer-service.yml` | Customer service |
| `manifests/order-service.yml` | Order service |
| `manifests/browser-traffic.yml` | Browser traffic generator |
| `manifests/load-traffic.yml` | Load traffic generator |

### Utility Manifests

| Manifest | Description |
|----------|-------------|
| `manifests/dynatrace-oneagent-metadata-viewer.yaml` | OneAgent metadata viewer pod |
