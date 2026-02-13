# Migration Plan: Monaco to dtctl - COMPLETED

## Status: MIGRATION COMPLETE

This migration moved Dynatrace configuration management from Monaco to dtctl for Settings 2.0 and SLOs, while keeping Monaco only for Classic API configurations.

---

## What Changed

### Migrated to dtctl

| Configuration | Schema | File |
|--------------|--------|------|
| Auto-tags (3 rules) | `builtin:tags.auto-tagging` | `dtctl/settings/auto-tags.yaml` |
| Management Zones (4) | `builtin:management-zones` | `dtctl/settings/management-zones.yaml` |
| Kubernetes Experience | `builtin:app-transition.kubernetes` | `dtctl/settings/kubernetes-experience.yaml` |
| Vulnerability Analytics | `builtin:appsec.runtime-vulnerability-detection` | `dtctl/settings/vulnerability-analytics.yaml` |
| SLOs (3) | SLO API v2 | `dtctl/slos/slos.yaml` |

### Kept with Monaco (Classic API)

| Configuration | API | Project |
|--------------|-----|---------|
| Custom Service (.NET) | `custom-service-dotnet` | easytrade |
| Conditional Naming | `conditional-naming-processgroup` | k8 |
| Dashboard | `dashboard` | db |
| Synthetic Monitors (3) | `synthetic-monitor` | synthetics |

### Kept as Direct API Calls

- Frequent Issue Detection (`/api/config/v1/frequentIssueDetection`)
- Service Anomaly Detection (`/api/config/v1/anomalyDetection/services`)

---

## Final Directory Structure

```
workshop-config/
├── dtctl/                           # NEW - dtctl configurations
│   ├── settings/
│   │   ├── auto-tags.yaml           # 3 auto-tagging rules
│   │   ├── management-zones.yaml    # 4 management zones
│   │   ├── kubernetes-experience.yaml
│   │   └── vulnerability-analytics.yaml
│   └── slos/
│       └── slos.yaml                # 3 SLO definitions
│
├── monaco-v2/                       # REDUCED - Classic API only
│   ├── manifest.yaml                # Only 4 projects now
│   └── projects/
│       ├── easytrade/
│       │   └── custom-service/      # NotMiningBitcoin
│       ├── k8/
│       │   └── conditional-naming-processgroup/
│       ├── db/
│       │   └── dashboard/
│       └── synthetics/
│           └── synthetic-monitor/
│
├── custom/                          # Direct API configs (unchanged)
│   ├── service-anomalydetection.json
│   └── service-anomalydetectionDefault.json
│
├── setup-workshop-config.sh         # UPDATED - Orchestrates dtctl + Monaco
└── _workshop-config.lib             # Direct API functions (unchanged)
```

### Removed Directories (migrated to dtctl)
- `monaco-v2/projects/workshop/` (entire directory)
- `monaco-v2/projects/services-vm/` (entire directory)
- `monaco-v2/projects/k8/management-zone/`
- `monaco-v2/projects/k8/slo/`
- `monaco-v2/projects/easytrade/management-zone/`

---

## Script Changes

### setup-workshop-config.sh
- Downloads both dtctl and Monaco
- Deploys dtctl Settings 2.0 configs first
- Deploys dtctl SLOs second
- Deploys Monaco Classic API configs last
- Applies custom Dynatrace settings via direct API

### setup-azure-workshop.sh
- Removed separate `configure_dynatrace_settings()` step (now in dtctl)
- Updated `deploy_monaco_configuration()` to reflect dtctl + Monaco usage
- Updated summary messages

---

## Token Requirements

### Current Token (unchanged)
The existing API token with these scopes works for both dtctl and Monaco:
```
settings.read
settings.write
slo.read
slo.write
ReadConfig
WriteConfig
```

### Optional: Separate Platform Token for dtctl
If you want to use a dedicated Platform token for dtctl:
```
settings:objects:read
settings:objects:write
settings:schemas:read
slo:read
slo:write
```

---

## Deployment Flow

```
setup-azure-workshop.sh
    └── deploy_monaco_configuration()
            └── setup-workshop-config.sh
                    ├── Step 1: Download dtctl + Monaco
                    ├── Step 2: dtctl deploy Settings 2.0
                    │   ├── auto-tags.yaml
                    │   ├── management-zones.yaml
                    │   ├── kubernetes-experience.yaml
                    │   └── vulnerability-analytics.yaml
                    ├── Step 2: dtctl deploy SLOs
                    │   └── slos.yaml
                    ├── Step 3: Monaco deploy Classic API
                    │   ├── k8 (conditional naming)
                    │   └── easytrade (custom service)
                    └── Step 4: Direct API calls
                        ├── setFrequentIssueDetectionOff
                        └── setServiceAnomalyDetection
```

---

## Testing

To test the migration:

```bash
cd workshop-config
export DT_BASEURL="https://your-env.live.dynatrace.com"
export DT_API_TOKEN="your-token"
export EMAIL="your@email.com"
export DT_ENVIRONMENT_ID="your-env-id"

# Run full deployment
./setup-workshop-config.sh

# Or with verbose output
./setup-workshop-config.sh --verbose
```

---

## Rollback

If you need to revert:
1. Restore the old `setup-workshop-config.sh` from git
2. Restore the removed Monaco directories from git
3. The `configure_dynatrace_settings()` function is still available in setup-azure-workshop.sh (marked as legacy)

---

## Benefits Achieved

1. **Modern tooling**: dtctl provides kubectl-style CLI experience
2. **Cleaner YAML**: dtctl configs are more readable than Monaco JSON templates
3. **Reduced Monaco footprint**: Monaco now only handles 4 Classic API projects
4. **Consolidated deployment**: Single script orchestrates both tools
5. **Future-ready**: Can easily add notebooks, workflows via dtctl later
