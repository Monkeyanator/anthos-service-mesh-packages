validate_managed_control_plane() {
  if can_modify_gcp_iam_roles; then
    bind_user_to_iam_policy "roles/meshconfig.admin" "$(local_iam_user)"
  fi
  if can_modify_at_all; then
    if ! init_meshconfig_managed; then
      fatal "Couldn't initialize meshconfig, do you have the required permission resourcemanager.projects.setIamPolicy?"
    fi
  fi
}

install_managed_control_plane() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  local POST_DATA; POST_DATA="{}";
  if [[ -n "${_CI_CLOUDRUN_IMAGE_HUB}" ]]; then
    POST_DATA="$(echo "${POST_DATA}" | jq -r --arg IMAGE "${_CI_CLOUDRUN_IMAGE_HUB}:${_CI_CLOUDRUN_IMAGE_TAG}" '. + {image: $IMAGE}')"
  fi

  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    POST_DATA="$(echo "${POST_DATA}" | jq -r --arg MEMBERSHIP "${HUB_IDP_URL/*projects/projects}" '. + {membership: $MEMBERSHIP}')"
  fi

  info "Provisioning control plane..."
  retry 2 check_curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${POST_DATA}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")

  local MUTATING_WEBHOOK_URL
  MUTATING_WEBHOOK_URL=$(get_managed_mutating_webhook_url)

  local VALIDATION_URL
  # shellcheck disable=SC2001
  VALIDATION_URL="$(echo "${MUTATING_WEBHOOK_URL}" | sed 's/inject.*$/validate/g')"

  local CLOUDRUN_ADDR
  # shellcheck disable=SC2001
  CLOUDRUN_ADDR=$(echo "${MUTATING_WEBHOOK_URL}" | cut -d'/' -f3)

  kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
  kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"

  info "Configuring ASM managed control plane revision CRD..."
  context_append "kubectlFiles" "${CRD_CONTROL_PLANE_REVISION}"

  info "Configuring base installation for managed control plane..."
  context_append "kubectlFiles" "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  context_append "kubectlFiles" "${MANAGED_WEBHOOKS}"

  install_mananged_cni
}

install_mananged_cni() {
  info "Configuring CNI..."
  local ASM_OPTS
  ASM_OPTS="$(kubectl -n istio-system \
    get --ignore-not-found cm asm-options \
    -o jsonpath='{.data.ASM_OPTS}' || true)"

  if [[ -z "${ASM_OPTS}" || "${ASM_OPTS}" != *"CNI=on"* ]]; then
    cat >mcp_configmap.yaml <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: asm-options
  namespace: istio-system
data:
  ASM_OPTS: "CNI=on"
EOF

    context_append "kubectlFiles" "mcp_configmap.yaml"
  fi

  context_append "kubectlFiles" "${MANAGED_CNI}"
}

configure_managed_control_plane() {
  :
}

get_managed_mutating_webhook_url() {
  # Get the url for the most up to date channel that the cluster is using.
  local WEBHOOKS; WEBHOOKS="istiod-asm-managed-rapid istiod-asm-managed istiod-asm-managed-stable"
  local WEBHOOK_JSON

  for WEBHOOK in $WEBHOOKS; do
    if WEBHOOK_JSON="$(kubectl get mutatingwebhookconfiguration "${WEBHOOK}" -ojson)" ; then
      info "Using the following managed revision for validating webhook: ${WEBHOOK#'istiod-'}"
      echo "$WEBHOOK_JSON" | jq .webhooks[0].clientConfig.url -r
      return
    fi
  done

  fatal "Could not find managed config map."
}


init_meshconfig_managed() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig managed API..."
  local POST_DATA
  # When cluster local project is the same as the Hub Hosting Project
  # Initialize the project with Hub WIP and prepare istiod
  if [[ "${FLEET_ID}" == "${PROJECT_ID}" ]]; then
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"], "prepare_istiod": true}'
    init_meshconfig_curl "${POST_DATA}" "${FLEET_ID}"
  # When cluster local project is different from the Hub Hosting Project
  # Initialize the Hub Hosting project with Hub WIP
  # Initialize the cluster local project with Hub WIP & GKE WIP and prepare istiod
  else
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"]}'
    init_meshconfig_curl "${POST_DATA}" "${FLEET_ID}"
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog","'${PROJECT_ID}'.svc.id.goog"], "prepare_istiod": true}'
    init_meshconfig_curl "${POST_DATA}" "${PROJECT_ID}"
  fi
}
