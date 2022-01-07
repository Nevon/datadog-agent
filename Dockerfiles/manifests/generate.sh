#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

if sed --version 2>/dev/null | grep -q "GNU sed"; then
    SED=sed
elif gsed --version 2>/dev/null | grep -q "GNU sed"; then
    SED=gsed
fi

cd "$(dirname "$0")"

#helm repo add datadog https://helm.datadoghq.com
helm repo update

TMPDIR=$(mktemp -d)
trap 'rm -r $TMPDIR' EXIT

cat > "$TMPDIR/values-agent-only.yaml" <<EOF
datadog:
  collectEvents: true
  leaderElection: true
  apm:
    socketEnabled: false
  processAgent:
    enabled: false
EOF

cat > "$TMPDIR/values-all-containers.yaml" <<EOF
datadog:
  collectEvents: true
  leaderElection: true
  logs:
    enabled: true
  apm:
    enabled: true
  processAgent:
    enabled: true
  networkMonitoring:
    enabled: true
  securityAgent:
    compliance:
      enabled: true
    runtime:
      enabled: true
EOF

cat > "$TMPDIR/values-cluster-agent.yaml" <<EOF
datadog:
  collectEvents: true
  apm:
    socketEnabled: false
  processAgent:
    enabled: false
clusterAgent:
  enabled: true
  metricsProvider:
    enabled: true
EOF

cat > "$TMPDIR/values-cluster-agent-datadogmetrics.yaml" <<EOF
datadog:
  collectEvents: true
  apm:
    socketEnabled: false
  processAgent:
    enabled: false
clusterAgent:
  enabled: true
  metricsProvider:
    enabled: true
    useDatadogMetrics: true
EOF

cat > "$TMPDIR/values-cluster-checks-runners.yaml" <<EOF
datadog:
  collectEvents: true
  apm:
    socketEnabled: false
  processAgent:
    enabled: false
  clusterChecks:
    enabled: true
clusterAgent:
  enabled: true
  metricsProvider:
    enabled: true
clusterChecksRunner:
  enabled: true
EOF

cat > "$TMPDIR/values-orchestrator-explorer.yaml" <<EOF
datadog:
  collectEvents: true
  apm:
    socketEnabled: false
  processAgent:
    enabled: true
  orchestratorExplorer:
    enabled: true
clusterAgent:
  enabled: true
EOF

cat > "$TMPDIR/values-security-agent.yaml" <<EOF
datadog:
  apm:
    socketEnabled: false
  securityAgent:
    compliance:
      enabled: true
    runtime:
      enabled: true
EOF

cat > "$TMPDIR/values-kubernetes_state_core.yaml" <<EOF
datadog:
  apm:
    socketEnabled: false
  kubeStateMetricsEnabled: false
  kubeStateMetricsCore:
    enabled: true
EOF

CLEANUP_INSTRUCTIONS='del(.metadata.labels."helm.sh/chart") | del(.metadata.labels."app.kubernetes.io/*") | del(.metadata.annotations.checksum/*) | del(.spec.template.metadata.annotations.checksum/*)'

for values in "$TMPDIR"/values-*.yaml; do
    type=${values##*values-}
    type=${type%.yaml}

    rm -rf "${type:?}"
    mkdir "${type:?}"

    helm template --kube-version 1.21 --namespace default datadog "${HELM_DATADOG_CHART:-datadog/datadog}" --values "$values" --output-dir "$TMPDIR/generated_$type"
    for file in "$TMPDIR/generated_$type"/datadog/templates/*.yaml; do
        # Skip files containing only comments like `containers-common-env.yaml`
        if [[ "$(yq eval '. | length' "$file")" == 0 ]]; then
            rm "$file"
            continue
        fi
        ${SED:-sed} -E -i 's/^# Source: (.*)/# This file has been generated by `helm template datadog-agent datadog\/datadog` from \1. Please re-run `generate.sh` rather than modifying this file manually./' "$file"
        yq eval "$CLEANUP_INSTRUCTIONS" "$file" > "$type/$(basename "$file")"
        ${SED:-sed} -E -i 's/(api-key: )".*"/\1PUT_YOUR_BASE64_ENCODED_API_KEY_HERE/;
                           s/(app-key: )".*"/\1PUT_YOUR_BASE64_ENCODED_APP_KEY_HERE/;
                           s/(token: ).*/\1PUT_A_BASE64_ENCODED_RANDOM_STRING_HERE/;
                           s/((tool|tool_version|installer_version): ).*/\1kubernetes sample manifests/;
            ' "$type/$(basename "$file")"
    done

    cat > "$type/README.md" <<EOF
The kubernetes manifests found in this directory have been automatically generated
from the [helm chart \`datadog/datadog\`](https://github.com/DataDog/helm-charts/tree/master/charts/datadog)
version $(helm show chart datadog/datadog | yq e '.version' -) with the following \`values.yaml\`:

\`\`\`yaml
$(<"$values")
\`\`\`
EOF
done
