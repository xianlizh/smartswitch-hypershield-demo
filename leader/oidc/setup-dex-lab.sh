#!/usr/bin/env bash

set -euo pipefail
umask 077

DEX_CHART_VERSION="${DEX_CHART_VERSION:-0.22.0}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
DEX_NODE_PORT="${DEX_NODE_PORT:-32000}"
DEX_CLIENT_ID="${DEX_CLIENT_ID:-hs-lab}"
DEX_SERVICE_TYPE="${DEX_SERVICE_TYPE:-NodePort}"
DEX_OUTPUT_DIR="${DEX_OUTPUT_DIR:-${PWD}/dex-lab}"
DEX_IN_CLUSTER_CURL_IMAGE="${DEX_IN_CLUSTER_CURL_IMAGE:-curlimages/curl:8.16.0}"
TIMESCAPE_NAMESPACE="${TIMESCAPE_NAMESPACE:-hubble-timescape}"
TIMESCAPE_UI_INGRESS_CLASS="${TIMESCAPE_UI_INGRESS_CLASS:-nginx}"
TIMESCAPE_UI_TLS_SECRET="${TIMESCAPE_UI_TLS_SECRET:-hubble-timescape-ui-ingress-tls}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} must be set"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is not installed: $1"
}

validate_inputs() {
  require_env KUBECONFIG
  require_env TIMESCAPE_UI_HOSTNAME
  require_env DEX_ADMIN_EMAIL

  if [[ -z "${DEX_ADMIN_PASSWORD:-}" && -z "${DEX_ADMIN_PASSWORD_HASH:-}" ]]; then
    die "set DEX_ADMIN_PASSWORD or DEX_ADMIN_PASSWORD_HASH"
  fi
  if [[ -n "${DEX_ADMIN_PASSWORD:-}" && -n "${DEX_ADMIN_PASSWORD_HASH:-}" ]]; then
    die "set only one of DEX_ADMIN_PASSWORD or DEX_ADMIN_PASSWORD_HASH"
  fi
  if [[ -n "${DEX_ADMIN_PASSWORD_HASH:-}" && ! "${DEX_ADMIN_PASSWORD_HASH}" =~ ^\$2[aby]\$[0-9]{2}\$.{53}$ ]]; then
    die "DEX_ADMIN_PASSWORD_HASH must be a bcrypt hash"
  fi
  [[ "${DEX_NODE_PORT}" =~ ^[0-9]+$ ]] || die "DEX_NODE_PORT must be numeric"
  [[ "${DEX_CLIENT_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "DEX_CLIENT_ID contains unsupported characters"
  [[ "${DEX_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "DEX_NAMESPACE must be a Kubernetes namespace name"
  [[ "${TIMESCAPE_UI_HOSTNAME}" =~ ^[A-Za-z0-9.-]+$ ]] || die "TIMESCAPE_UI_HOSTNAME must be a DNS hostname without a scheme, port, or path"
  case "${DEX_SERVICE_TYPE}" in
    NodePort|LoadBalancer) ;;
    *) die "DEX_SERVICE_TYPE must be NodePort or LoadBalancer" ;;
  esac
  if [[ "${DEX_SERVICE_TYPE}" == "LoadBalancer" && -z "${DEX_ISSUER_HOST:-}" ]]; then
    die "DEX_ISSUER_HOST must be set when DEX_SERVICE_TYPE is LoadBalancer"
  fi
}

validate_tools_and_cluster() {
  local command
  for command in cmp curl helm jq kubectl openssl yq; do
    require_command "${command}"
  done
  if [[ -n "${DEX_ADMIN_PASSWORD:-}" ]]; then
    require_command htpasswd
  fi
  kubectl version --request-timeout=15s >/dev/null
  kubectl auth can-i get nodes >/dev/null
}

is_ipv4() {
  local host="$1"
  local octet
  [[ "${host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "${host}"
  for octet in "${octets[@]}"; do
    ((10#${octet} <= 255)) || return 1
  done
}

resolve_issuer() {
  local host="${DEX_ISSUER_HOST:-}"
  local port="${DEX_ISSUER_PORT:-}"

  if [[ -z "${host}" ]]; then
    host="$(kubectl get nodes -o json | jq -er '
      [.items[]
       | select((.metadata.labels // {} | has("node-role.kubernetes.io/control-plane")) | not)
       | select((.metadata.labels // {} | has("node-role.kubernetes.io/master")) | not)
       | .status.addresses[]
       | select(.type == "InternalIP")
       | .address][0] //
      [.items[] | .status.addresses[] | select(.type == "InternalIP") | .address][0]
    ')" || die "failed to determine a node InternalIP for Dex"
    cat >&2 <<EOF
WARNING: DEX_ISSUER_HOST is not set. Using worker InternalIP ${host}.
This disposable-lab fallback makes the OIDC issuer depend on one node. Replacing
that node can invalidate the issuer and break Timescape UI login. Prefer stable
DNS or a stable load-balancer address through DEX_ISSUER_HOST.
EOF
  fi

  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || die "DEX_ISSUER_HOST must be a DNS hostname or IPv4 address"
  if [[ -z "${port}" ]]; then
    if [[ "${DEX_SERVICE_TYPE}" == "LoadBalancer" ]]; then
      port=443
    else
      port="${DEX_NODE_PORT}"
    fi
  fi
  [[ "${port}" =~ ^[0-9]+$ ]] || die "DEX_ISSUER_PORT must be numeric"

  DEX_LAB_ISSUER_HOST="${host}"
  DEX_LAB_ISSUER_PORT="${port}"
  if [[ "${port}" == "443" ]]; then
    DEX_LAB_ISSUER_URL="https://${host}"
  else
    DEX_LAB_ISSUER_URL="https://${host}:${port}"
  fi
}

check_preserved_issuer() {
  local env_file="${DEX_OUTPUT_DIR}/dex-lab.env"
  local state_file="${DEX_OUTPUT_DIR}/dex-issuer-url"
  local previous=""
  if [[ -s "${state_file}" ]]; then
    previous="$(< "${state_file}")"
  elif [[ -f "${env_file}" ]]; then
    previous="$(sed -n 's/^export DEX_ISSUER_URL=//p' "${env_file}")"
  elif [[ -e "${DEX_OUTPUT_DIR}/dex-tls.crt" ]]; then
    die "existing Dex TLS material has no issuer state; use its original endpoint or a new DEX_OUTPUT_DIR"
  fi
  if [[ -n "${previous}" && "${previous}" != "${DEX_LAB_ISSUER_URL}" ]]; then
    die "existing Dex state uses issuer ${previous}; refusing to replace it with ${DEX_LAB_ISSUER_URL}. Use the original endpoint or a new DEX_OUTPUT_DIR"
  fi
}

check_cluster_tls_state() {
  kubectl -n "${DEX_NAMESPACE}" get secret dex-tls >/dev/null 2>&1 || return 0
  if [[ ! -s "${DEX_OUTPUT_DIR}/dex-tls.crt" || ! -s "${DEX_OUTPUT_DIR}/dex-tls.key" ]]; then
    die "${DEX_NAMESPACE}/dex-tls already exists but ${DEX_OUTPUT_DIR} has no matching persistent TLS state; restore the original output directory instead of rotating the issuer certificate"
  fi

  local encoded_cert
  local cluster_cert="${DEX_LAB_WORK_DIR}/cluster-dex-tls.crt"
  encoded_cert="$(kubectl -n "${DEX_NAMESPACE}" get secret dex-tls -o jsonpath='{.data.tls\.crt}')"
  [[ -n "${encoded_cert}" ]] || die "existing ${DEX_NAMESPACE}/dex-tls has no tls.crt"
  printf '%s' "${encoded_cert}" | openssl base64 -d -A > "${cluster_cert}"
  cmp -s "${cluster_cert}" "${DEX_OUTPUT_DIR}/dex-tls.crt" || \
    die "existing ${DEX_NAMESPACE}/dex-tls differs from ${DEX_OUTPUT_DIR}; refusing to rotate the issuer certificate"
}

ensure_tls_material() {
  local ca_key="${DEX_OUTPUT_DIR}/dex-ca.key"
  local ca_cert="${DEX_OUTPUT_DIR}/dex-ca.crt"
  local tls_key="${DEX_OUTPUT_DIR}/dex-tls.key"
  local tls_cert="${DEX_OUTPUT_DIR}/dex-tls.crt"
  local present=0
  local file

  for file in "${ca_key}" "${ca_cert}" "${tls_key}" "${tls_cert}"; do
    [[ -e "${file}" ]] && present=$((present + 1))
  done
  if ((present > 0 && present < 4)); then
    die "incomplete TLS state in ${DEX_OUTPUT_DIR}; refusing to rotate only part of the Dex trust chain"
  fi
  if ((present == 4)); then
    echo "Reusing Dex CA and serving certificate from ${DEX_OUTPUT_DIR}"
    return 0
  fi

  local openssl_config="${DEX_LAB_WORK_DIR}/openssl.cnf"
  local san_type="DNS"
  is_ipv4 "${DEX_LAB_ISSUER_HOST}" && san_type="IP"
  cat > "${openssl_config}" <<EOF
[req]
distinguished_name = subject
prompt = no
req_extensions = v3_req
[subject]
CN = ${DEX_LAB_ISSUER_HOST}
[v3_req]
subjectAltName = ${san_type}:${DEX_LAB_ISSUER_HOST}
extendedKeyUsage = serverAuth
keyUsage = critical,digitalSignature,keyEncipherment
EOF

  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout "${ca_key}" -out "${ca_cert}" \
    -subj "/CN=Hypershield Lab Dex CA" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "${tls_key}" -out "${DEX_LAB_WORK_DIR}/dex-tls.csr" \
    -config "${openssl_config}" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 825 \
    -in "${DEX_LAB_WORK_DIR}/dex-tls.csr" \
    -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial \
    -out "${tls_cert}" -extensions v3_req -extfile "${openssl_config}" >/dev/null 2>&1
  rm -f "${DEX_OUTPUT_DIR}/dex-ca.srl"
  chmod 0600 "${ca_key}" "${ca_cert}" "${tls_key}" "${tls_cert}"
  printf '%s\n' "${DEX_LAB_ISSUER_URL}" > "${DEX_OUTPUT_DIR}/dex-issuer-url"
  chmod 0600 "${DEX_OUTPUT_DIR}/dex-issuer-url"
  echo "Created a persistent Dex CA and serving certificate for ${DEX_LAB_ISSUER_HOST}"
}

ensure_client_secret() {
  local path="${DEX_OUTPUT_DIR}/ui-client-secret"
  if [[ ! -s "${path}" ]]; then
    openssl rand -hex 32 > "${path}"
    chmod 0600 "${path}"
    echo "Created persistent OIDC client secret in ${path}"
  else
    echo "Reusing OIDC client secret from ${path}"
  fi
}

ensure_admin_password_hash() {
  local path="${DEX_OUTPUT_DIR}/dex-admin-password-hash"
  local requested_hash="${DEX_ADMIN_PASSWORD_HASH:-}"

  if [[ -s "${path}" ]]; then
    DEX_LAB_ADMIN_PASSWORD_HASH="$(< "${path}")"
    if [[ -n "${requested_hash}" && "${requested_hash}" != "${DEX_LAB_ADMIN_PASSWORD_HASH}" ]]; then
      die "DEX_ADMIN_PASSWORD_HASH differs from preserved state in ${path}; refusing to rotate the lab identity"
    fi
    if [[ -n "${DEX_ADMIN_PASSWORD:-}" ]]; then
      local verify_file="${DEX_LAB_WORK_DIR}/htpasswd"
      printf 'admin:%s\n' "${DEX_LAB_ADMIN_PASSWORD_HASH}" > "${verify_file}"
      htpasswd -vb "${verify_file}" admin "${DEX_ADMIN_PASSWORD}" >/dev/null 2>&1 || \
        die "DEX_ADMIN_PASSWORD does not match the preserved password identity"
    fi
    echo "Reusing the preserved Dex password identity"
    return 0
  fi

  if [[ -n "${requested_hash}" ]]; then
    DEX_LAB_ADMIN_PASSWORD_HASH="${requested_hash}"
  else
    DEX_LAB_ADMIN_PASSWORD_HASH="$(htpasswd -bnBC 10 admin "${DEX_ADMIN_PASSWORD}" | sed 's/^admin://' | tr -d '\n')"
  fi
  printf '%s\n' "${DEX_LAB_ADMIN_PASSWORD_HASH}" > "${path}"
  chmod 0600 "${path}"
  echo "Created a persistent Dex password identity"
}

write_dex_values() {
  local values_file="${DEX_OUTPUT_DIR}/dex-values.yaml"
  local client_secret
  client_secret="$(< "${DEX_OUTPUT_DIR}/ui-client-secret")"

  DEX_LAB_ISSUER_URL="${DEX_LAB_ISSUER_URL}" \
  DEX_LAB_ADMIN_EMAIL="${DEX_ADMIN_EMAIL}" \
  DEX_LAB_ADMIN_HASH="${DEX_LAB_ADMIN_PASSWORD_HASH}" \
  DEX_LAB_CLIENT_ID="${DEX_CLIENT_ID}" \
  DEX_LAB_CLIENT_SECRET="${client_secret}" \
  DEX_LAB_REDIRECT_URL="https://${TIMESCAPE_UI_HOSTNAME}/oauth2/callback" \
  DEX_LAB_NODE_PORT="${DEX_NODE_PORT}" \
  DEX_LAB_SERVICE_TYPE="${DEX_SERVICE_TYPE}" \
  DEX_LAB_SERVICE_PORT="${DEX_LAB_ISSUER_PORT}" \
    yq -n '
      .fullnameOverride = "dex" |
      .https.enabled = true |
      .service.type = strenv(DEX_LAB_SERVICE_TYPE) |
      .service.ports.https.nodePort = (strenv(DEX_LAB_NODE_PORT) | tonumber) |
      .volumes = [{"name": "dex-tls", "secret": {"secretName": "dex-tls"}}] |
      .volumeMounts = [{"name": "dex-tls", "mountPath": "/etc/dex/tls", "readOnly": true}] |
      .config.issuer = strenv(DEX_LAB_ISSUER_URL) |
      .config.storage.type = "memory" |
      .config.web.https = "0.0.0.0:5554" |
      .config.web.tlsCert = "/etc/dex/tls/tls.crt" |
      .config.web.tlsKey = "/etc/dex/tls/tls.key" |
      .config.oauth2.passwordConnector = "local" |
      .config.oauth2.skipApprovalScreen = true |
      .config.enablePasswordDB = true |
      .config.staticPasswords = [{"email": strenv(DEX_LAB_ADMIN_EMAIL), "hash": strenv(DEX_LAB_ADMIN_HASH), "username": "admin", "userID": "hs-lab-admin"}] |
      .config.staticClients = [{"id": strenv(DEX_LAB_CLIENT_ID), "name": "Hypershield Lab", "secret": strenv(DEX_LAB_CLIENT_SECRET), "public": false, "redirectURIs": [strenv(DEX_LAB_REDIRECT_URL)]}]
    ' > "${values_file}"

  if [[ "${DEX_SERVICE_TYPE}" == "LoadBalancer" ]]; then
    DEX_LAB_SERVICE_PORT="${DEX_LAB_ISSUER_PORT}" yq -i \
      '.service.ports.https.port = (strenv(DEX_LAB_SERVICE_PORT) | tonumber) | del(.service.ports.https.nodePort)' \
      "${values_file}"
  fi
  chmod 0600 "${values_file}"
}

write_timescape_values() {
  local values_file="${DEX_OUTPUT_DIR}/timescape-oidc-values.yaml"
  DEX_LAB_ISSUER_URL="${DEX_LAB_ISSUER_URL}" \
  DEX_LAB_ADMIN_EMAIL="${DEX_ADMIN_EMAIL}" \
  DEX_LAB_CLIENT_ID="${DEX_CLIENT_ID}" \
  DEX_LAB_UI_HOSTNAME="${TIMESCAPE_UI_HOSTNAME}" \
  DEX_LAB_UI_INGRESS_CLASS="${TIMESCAPE_UI_INGRESS_CLASS}" \
  DEX_LAB_UI_TLS_SECRET="${TIMESCAPE_UI_TLS_SECRET}" \
    yq -n '
      .server.rbac.oidcURL = strenv(DEX_LAB_ISSUER_URL) |
      .server.rbac.oidcClientID = strenv(DEX_LAB_CLIENT_ID) |
      .server.rbac.oidcCA.configMap.name = "oidc-ca" |
      .server.rbac.oidcCA.configMap.key = "ca.crt" |
      .server.rbac.policy.configMap.bindings = [{"role": "hypershield:administrator", "type": "identity", "field": "username", "value": strenv(DEX_LAB_ADMIN_EMAIL)}] |
      .ui.enabled = true |
      .ui.secureCookies = "true" |
      .ui.tls.enabled = false |
      .ui.auth.enabled = true |
      .ui.auth.oidc.issuerURL = strenv(DEX_LAB_ISSUER_URL) |
      .ui.auth.oidc.clientID = strenv(DEX_LAB_CLIENT_ID) |
      .ui.auth.oidc.redirectURL = ("https://" + strenv(DEX_LAB_UI_HOSTNAME) + "/oauth2/callback") |
      .ui.auth.oidc.issuerCA.configMap.name = "oidc-ca" |
      .ui.auth.oidc.issuerCA.configMap.key = "ca.crt" |
      .ui.ingress.enabled = true |
      .ui.ingress.host = strenv(DEX_LAB_UI_HOSTNAME) |
      .ui.ingress.ingressClassName = strenv(DEX_LAB_UI_INGRESS_CLASS) |
      .ui.ingress.annotations."cert-manager.io/cluster-issuer" = "hypershield-self-signed-ca-clusterissuer" |
      .ui.ingress.annotations."nginx.ingress.kubernetes.io/backend-protocol" = "HTTP" |
      .ui.ingress.tls.enabled = true |
      .ui.ingress.tls.secretName = strenv(DEX_LAB_UI_TLS_SECRET)
    ' > "${values_file}"
  chmod 0600 "${values_file}"
}

resolve_chart() {
  if [[ -n "${DEX_CHART:-}" ]]; then
    [[ -f "${DEX_CHART}" ]] || die "DEX_CHART does not exist: ${DEX_CHART}"
    DEX_LAB_CHART_REF="${DEX_CHART}"
    DEX_LAB_HELM_VERSION_ARGS=()
    return 0
  fi
  helm repo add --force-update dex https://charts.dexidp.io >/dev/null
  helm repo update dex >/dev/null
  DEX_LAB_CHART_REF="dex/dex"
  DEX_LAB_HELM_VERSION_ARGS=(--version "${DEX_CHART_VERSION}")
}

install_dex() {
  kubectl create namespace "${DEX_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${DEX_NAMESPACE}" create secret tls dex-tls \
    --cert="${DEX_OUTPUT_DIR}/dex-tls.crt" \
    --key="${DEX_OUTPUT_DIR}/dex-tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${DEX_NAMESPACE}" create configmap dex-ca \
    --from-file="ca.crt=${DEX_OUTPUT_DIR}/dex-ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  helm upgrade --install dex "${DEX_LAB_CHART_REF}" \
    "${DEX_LAB_HELM_VERSION_ARGS[@]}" \
    --namespace "${DEX_NAMESPACE}" \
    --values "${DEX_OUTPUT_DIR}/dex-values.yaml" \
    --wait --timeout 5m
  kubectl -n "${DEX_NAMESPACE}" rollout status deployment/dex --timeout=5m
}

ensure_timescape_oidc_resources() {
  local ui_secret_marker="self-managed.isovalent.com/secret-hubble-timescape-ui"
  kubectl create namespace "${TIMESCAPE_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${TIMESCAPE_NAMESPACE}" create configmap oidc-ca \
    --from-file="ca.crt=${DEX_OUTPUT_DIR}/dex-ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if kubectl -n "${TIMESCAPE_NAMESPACE}" get secret hubble-timescape-ui >/dev/null 2>&1; then
    local existing_client="${DEX_LAB_WORK_DIR}/existing-client-secret"
    local encoded
    encoded="$(kubectl -n "${TIMESCAPE_NAMESPACE}" get secret hubble-timescape-ui -o jsonpath='{.data.client-secret}')"
    [[ -n "${encoded}" ]] || die "existing ${TIMESCAPE_NAMESPACE}/hubble-timescape-ui has no client-secret key"
    printf '%s' "${encoded}" | openssl base64 -d -A > "${existing_client}"
    cmp -s "${existing_client}" "${DEX_OUTPUT_DIR}/ui-client-secret" || \
      die "existing ${TIMESCAPE_NAMESPACE}/hubble-timescape-ui has a different client secret; refusing to rotate it"
    encoded="$(kubectl -n "${TIMESCAPE_NAMESPACE}" get secret hubble-timescape-ui -o jsonpath='{.data.session-key}')"
    [[ -n "${encoded}" ]] || die "existing ${TIMESCAPE_NAMESPACE}/hubble-timescape-ui has no session-key key"
    kubectl annotate namespace "${TIMESCAPE_NAMESPACE}" "${ui_secret_marker}=true" --overwrite >/dev/null
    echo "Reusing Timescape UI client secret and session key"
    return 0
  fi

  local was_provisioned
  was_provisioned="$(kubectl get namespace "${TIMESCAPE_NAMESPACE}" \
    -o "go-template={{ index .metadata.annotations \"${ui_secret_marker}\" }}" 2>/dev/null || true)"
  [[ "${was_provisioned}" != "true" ]] || \
    die "${TIMESCAPE_NAMESPACE}/hubble-timescape-ui was previously provisioned but is now missing; restore it instead of rotating the session key"

  local session_key
  session_key="$(openssl rand -base64 32 | tr -d '\n')"
  kubectl -n "${TIMESCAPE_NAMESPACE}" create secret generic hubble-timescape-ui \
    --from-file="client-secret=${DEX_OUTPUT_DIR}/ui-client-secret" \
    --from-literal="session-key=${session_key}" >/dev/null
  kubectl annotate namespace "${TIMESCAPE_NAMESPACE}" "${ui_secret_marker}=true" --overwrite >/dev/null
  echo "Created Timescape UI Secret with a persistent session key"
}

verify_discovery() {
  local discovery="${DEX_LAB_WORK_DIR}/discovery.json"
  curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-connrefused \
    --cacert "${DEX_OUTPUT_DIR}/dex-ca.crt" \
    "${DEX_LAB_ISSUER_URL}/.well-known/openid-configuration" > "${discovery}"
  jq -e --arg issuer "${DEX_LAB_ISSUER_URL}" '.issuer == $issuer' "${discovery}" >/dev/null || \
    die "Dex discovery issuer does not exactly match ${DEX_LAB_ISSUER_URL}"
  echo "Dex discovery succeeded from the invoking host"

  if [[ "${DEX_SKIP_IN_CLUSTER_CHECK:-false}" == "true" ]]; then
    echo "Skipping the optional in-cluster discovery check"
    return 0
  fi

  local pod_name="dex-discovery-check"
  kubectl -n "${DEX_NAMESPACE}" delete pod "${pod_name}" --ignore-not-found --wait=true >/dev/null
  cat > "${DEX_LAB_WORK_DIR}/discovery-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${DEX_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: ${DEX_IN_CLUSTER_CURL_IMAGE}
      args:
        - --fail
        - --silent
        - --show-error
        - --cacert
        - /ca/ca.crt
        - ${DEX_LAB_ISSUER_URL}/.well-known/openid-configuration
      volumeMounts:
        - name: ca
          mountPath: /ca
          readOnly: true
  volumes:
    - name: ca
      configMap:
        name: dex-ca
EOF
  kubectl apply -f "${DEX_LAB_WORK_DIR}/discovery-pod.yaml" >/dev/null
  if ! kubectl -n "${DEX_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=2m >/dev/null; then
    kubectl -n "${DEX_NAMESPACE}" logs "${pod_name}" >&2 || true
    die "Dex discovery failed from the temporary in-cluster pod"
  fi
  kubectl -n "${DEX_NAMESPACE}" logs "${pod_name}" > "${DEX_LAB_WORK_DIR}/in-cluster-discovery.json"
  jq -e --arg issuer "${DEX_LAB_ISSUER_URL}" '.issuer == $issuer' \
    "${DEX_LAB_WORK_DIR}/in-cluster-discovery.json" >/dev/null || \
    die "in-cluster discovery issuer does not exactly match ${DEX_LAB_ISSUER_URL}"
  kubectl -n "${DEX_NAMESPACE}" delete pod "${pod_name}" --wait=false >/dev/null
  echo "Dex discovery succeeded from inside the cluster"
}

write_outputs() {
  local env_file="${DEX_OUTPUT_DIR}/dex-lab.env"
  {
    printf 'export DEX_ISSUER_URL=%q\n' "${DEX_LAB_ISSUER_URL}"
    printf 'export DEX_CLIENT_ID=%q\n' "${DEX_CLIENT_ID}"
    printf 'export DEX_OUTPUT_DIR=%q\n' "${DEX_OUTPUT_DIR}"
    printf 'export DEX_CA_FILE=%q\n' "${DEX_OUTPUT_DIR}/dex-ca.crt"
    printf 'export TIMESCAPE_VALUES_FILE=%q\n' "${DEX_OUTPUT_DIR}/timescape-oidc-values.yaml"
  } > "${env_file}"
  chmod 0600 "${env_file}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    local client_secret
    client_secret="$(< "${DEX_OUTPUT_DIR}/ui-client-secret")"
    echo "::add-mask::${client_secret}"
    {
      echo "issuer_url=${DEX_LAB_ISSUER_URL}"
      echo "dex_ca_file=${DEX_OUTPUT_DIR}/dex-ca.crt"
      echo "ui_client_secret_file=${DEX_OUTPUT_DIR}/ui-client-secret"
      echo "timescape_values_file=${DEX_OUTPUT_DIR}/timescape-oidc-values.yaml"
    } >> "${GITHUB_OUTPUT}"
  fi

  echo
  echo "Dex lab OIDC is ready. Next run:"
  printf '  TIMESCAPE_VALUES_FILE=%q ./setup-timescape.sh\n' "${DEX_OUTPUT_DIR}/timescape-oidc-values.yaml"
}

cleanup() {
  if [[ -n "${DEX_LAB_WORK_DIR:-}" && -d "${DEX_LAB_WORK_DIR}" ]]; then
    rm -rf "${DEX_LAB_WORK_DIR}"
  fi
}

main() {
  validate_inputs
  validate_tools_and_cluster
  mkdir -p "${DEX_OUTPUT_DIR}"
  chmod 0700 "${DEX_OUTPUT_DIR}"
  DEX_OUTPUT_DIR="$(cd -- "${DEX_OUTPUT_DIR}" && pwd)"
  DEX_LAB_WORK_DIR="$(mktemp -d "${DEX_OUTPUT_DIR}/.work.XXXXXX")"
  trap cleanup EXIT

  resolve_issuer
  check_preserved_issuer
  check_cluster_tls_state
  ensure_tls_material
  ensure_client_secret
  ensure_admin_password_hash
  unset DEX_ADMIN_PASSWORD DEX_ADMIN_PASSWORD_HASH
  write_dex_values
  write_timescape_values
  resolve_chart
  install_dex
  ensure_timescape_oidc_resources
  verify_discovery
  write_outputs
}

if [[ "${DEX_LAB_LIB_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
