#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/mrrajan/trustify-helm-charts.git"
DEFAULT_BRANCH="TC-5205"
DEFAULT_IMAGE="registry.redhat.io/rhtpa/rhtpa-trustification-service-rhel9@sha256:4d024a6b748997b2cc757f53a7f0c3fe7f80789b74f7325837d93ecd0273bb58"

NAMESPACE=""
IMAGE=""
BRANCH="${DEFAULT_BRANCH}"
SKIP_CLONE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --namespace <ns> [OPTIONS]

Deploy Trustify with Squid proxy for QE validation (OCP-only mode).

Required:
  -n, --namespace   Target OpenShift namespace

Options:
  -i, --image       Full image reference (SHA digest or tag)
                    Default: RHTPA 2.2.6 (fixed) image
  -b, --branch      Git branch to checkout (default: ${DEFAULT_BRANCH})
      --skip-clone  Use current directory instead of cloning the repo
  -h, --help        Show this help

Example:
  $(basename "$0") -n tpaqev417proxy
  $(basename "$0") -n tpaqev417proxy -i registry.redhat.io/rhtpa/rhtpa-trustification-service-rhel9@sha256:abc123...
EOF
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -i|--image)     IMAGE="$2";     shift 2 ;;
    -b|--branch)    BRANCH="$2";    shift 2 ;;
    --skip-clone)   SKIP_CLONE=true; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
done

[[ -z "${NAMESPACE}" ]] && { echo "ERROR: --namespace is required"; usage 1; }

if [[ -z "${IMAGE}" ]]; then
  IMAGE="${DEFAULT_IMAGE}"
  echo "NOTE: No --image provided. Using default RHTPA 2.2.6 (fixed) image."
  echo "      ${IMAGE}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
ok()    { echo -e "\033[1;32m  ✓ $*\033[0m"; }
fail()  { echo -e "\033[1;31m  ✗ $*\033[0m"; }
wait_for_pods() {
  local label="$1" timeout="${2:-300}"
  local end=$((SECONDS + timeout))
  while [[ $SECONDS -lt $end ]]; do
    local ready
    ready=$(oc get pods -n "${NAMESPACE}" -l "${label}" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
    if [[ -n "${ready}" ]] && ! echo "${ready}" | grep -q "False"; then
      return 0
    fi
    sleep 5
  done
  echo "WARN: timed out waiting for pods with label ${label}"
  return 1
}

# ---------------------------------------------------------------------------
# Step 0: Clone repo (unless --skip-clone)
# ---------------------------------------------------------------------------
if [[ "${SKIP_CLONE}" == false ]]; then
  info "Cloning ${REPO_URL} (branch: ${BRANCH})"
  WORKDIR=$(mktemp -d)
  git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${WORKDIR}"
  cd "${WORKDIR}"
  ok "Cloned to ${WORKDIR}"
else
  info "Using current directory (--skip-clone)"
fi

# ---------------------------------------------------------------------------
# Step 1: Namespace — verify or create
# ---------------------------------------------------------------------------
info "Checking namespace: ${NAMESPACE}"
if oc get project "${NAMESPACE}" &>/dev/null; then
  ok "Namespace ${NAMESPACE} exists"
else
  info "Creating namespace ${NAMESPACE}"
  oc new-project "${NAMESPACE}" --skip-config-write
  ok "Namespace ${NAMESPACE} created"
fi

# ---------------------------------------------------------------------------
# Step 2: Derive APP_DOMAIN
# ---------------------------------------------------------------------------
info "Deriving APP_DOMAIN"
CLUSTER_DOMAIN=$(oc -n openshift-ingress-operator \
  get ingresscontrollers.operator.openshift.io default \
  -o jsonpath='{.status.domain}')
APP_DOMAIN="-${NAMESPACE}.${CLUSTER_DOMAIN}"
ok "APP_DOMAIN=${APP_DOMAIN}"

KEYCLOAK_HOSTNAME="sso-${NAMESPACE}.${CLUSTER_DOMAIN}"
ok "Keycloak hostname=${KEYCLOAK_HOSTNAME}"

# ---------------------------------------------------------------------------
# Step 3: Deploy Squid proxy + NetworkPolicy (OCP-only, no port-443 rule)
# ---------------------------------------------------------------------------
info "Deploying Squid proxy"
oc apply -f squid-proxy.yaml -n "${NAMESPACE}"
ok "Squid proxy resources applied"

info "Applying NetworkPolicy (OCP-only — port 443 direct egress blocked)"
TMPNP=$(mktemp)
sed '/# AWS mode only/,/protocol: TCP$/d' \
  networkpolicy-block-importer-egress.yaml > "${TMPNP}"
oc apply -f "${TMPNP}" -n "${NAMESPACE}"
rm -f "${TMPNP}"
ok "NetworkPolicy applied"

info "Waiting for Squid proxy to be ready"
oc rollout status deployment/squid-proxy -n "${NAMESPACE}" --timeout=120s
ok "Squid proxy is running"

# ---------------------------------------------------------------------------
# Step 4: Deploy infrastructure (Keycloak + PostgreSQL)
# ---------------------------------------------------------------------------
info "Deploying infrastructure"
helm upgrade --install --dependency-update \
  -n "${NAMESPACE}" infrastructure charts/trustify-infrastructure \
  --values values-ocp-no-aws.yaml \
  --set-string "keycloak.ingress.hostname=${KEYCLOAK_HOSTNAME}" \
  --set-string "appDomain=${APP_DOMAIN}" \
  --timeout 5m \
  --wait
ok "Infrastructure Helm release deployed"

info "Waiting for infrastructure pods"
wait_for_pods "app.kubernetes.io/instance=infrastructure" 300
ok "Infrastructure pods are ready"

# ---------------------------------------------------------------------------
# Step 5: Deploy Trustify with proxy test values
# ---------------------------------------------------------------------------
NO_PROXY="localhost,127.0.0.1,.svc,.cluster.local,trustify-server,infrastructure-postgresql,infrastructure-keycloak,${KEYCLOAK_HOSTNAME}"
NO_PROXY_ESCAPED="${NO_PROXY//,/\\,}"

info "Deploying Trustify (image: ${IMAGE})"
helm upgrade --install -n "${NAMESPACE}" trustify charts/trustify \
  --values values-ocp-no-aws.yaml \
  --values values-proxy-test.yaml \
  --set-string "appDomain=${APP_DOMAIN}" \
  --set-string "image.fullName=${IMAGE}" \
  --set 'image.name=null' \
  --set 'image.registry=null' \
  --set 'modules.importer.extraEnv[0].name=HTTP_PROXY' \
  --set 'modules.importer.extraEnv[0].value=http://squid-proxy:3128' \
  --set 'modules.importer.extraEnv[1].name=HTTPS_PROXY' \
  --set 'modules.importer.extraEnv[1].value=http://squid-proxy:3128' \
  --set 'modules.importer.extraEnv[2].name=NO_PROXY' \
  --set-string "modules.importer.extraEnv[2].value=${NO_PROXY_ESCAPED}" \
  --timeout 5m
ok "Trustify Helm release deployed"

info "Waiting for server pod"
wait_for_pods "app.kubernetes.io/component=server" 300
ok "Server pod is ready"

info "Waiting for importer pod"
wait_for_pods "app.kubernetes.io/component=importer" 300
ok "Importer pod is ready"

# ---------------------------------------------------------------------------
# Step 6: Validation
# ---------------------------------------------------------------------------
IMPORTER_POD=$(oc get pods -n "${NAMESPACE}" \
  -l app.kubernetes.io/component=importer \
  -o jsonpath='{.items[0].metadata.name}')

info "Validating proxy setup (importer pod: ${IMPORTER_POD})"

echo ""
echo "--- Test 1: HTTPS to GitHub WITH proxy (expect HTTP 200) ---"
RESULT_WITH=$(oc exec -n "${NAMESPACE}" "${IMPORTER_POD}" -- \
  curl -sS -o /dev/null -w "%{http_code}" --max-time 30 \
  https://github.com/CVEProject/cvelistV5/info/refs?service=git-upload-pack 2>&1) || true

if [[ "${RESULT_WITH}" == "200" ]]; then
  ok "WITH proxy: HTTP ${RESULT_WITH}"
  PROXY_PASS="PASS"
else
  fail "WITH proxy: HTTP ${RESULT_WITH}"
  PROXY_PASS="FAIL"
fi

echo ""
echo "--- Test 2: HTTPS to GitHub WITHOUT proxy (expect timeout/failure) ---"
RESULT_WITHOUT=$(oc exec -n "${NAMESPACE}" "${IMPORTER_POD}" -- \
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 15 --max-time 20 \
  https://github.com/CVEProject/cvelistV5/info/refs?service=git-upload-pack 2>&1) || true

if [[ "${RESULT_WITHOUT}" == "000" ]] || [[ "${RESULT_WITHOUT}" == *"timed out"* ]] || [[ "${RESULT_WITHOUT}" == *"Connection refused"* ]]; then
  ok "WITHOUT proxy: blocked (${RESULT_WITHOUT})"
  DIRECT_PASS="PASS"
else
  fail "WITHOUT proxy: unexpected response (${RESULT_WITHOUT})"
  DIRECT_PASS="FAIL"
fi

# ---------------------------------------------------------------------------
# Step 7: Squid access logs
# ---------------------------------------------------------------------------
echo ""
info "Squid proxy access logs (last 20 lines)"
oc logs -n "${NAMESPACE}" deployment/squid-proxy --tail=20 | grep -E "TCP_TUNNEL|CONNECT" || echo "(no CONNECT entries found)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "Summary"
echo "  ┌──────────────────────────────────┬────────┐"
echo "  │ Test                             │ Result │"
echo "  ├──────────────────────────────────┼────────┤"
printf "  │ HTTPS via proxy (expect 200)     │ %-6s │\n" "${PROXY_PASS}"
printf "  │ HTTPS direct   (expect blocked) │ %-6s │\n" "${DIRECT_PASS}"
echo "  └──────────────────────────────────┴────────┘"
echo ""
echo "  Namespace : ${NAMESPACE}"
echo "  Console   : https://server${APP_DOMAIN}"
echo "  Keycloak  : https://${KEYCLOAK_HOSTNAME}"
echo "  Squid logs: oc logs -n ${NAMESPACE} deployment/squid-proxy -f"
echo ""

if [[ "${PROXY_PASS}" == "PASS" && "${DIRECT_PASS}" == "PASS" ]]; then
  ok "All proxy validation checks passed"
  exit 0
else
  fail "Some checks failed — review output above"
  exit 1
fi
