#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${MODE:-hy3}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${HOME}/.local/src/llama.cpp-vid001}"
MODEL_PATH="${MODEL_PATH:-${HOME}/models/hy3/Hy3-IQ1_M-mtp.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8090}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-4096}"
MIN_TOKENS_PER_SECOND="${MIN_TOKENS_PER_SECOND:-15}"
TENSOR_SPLIT="${TENSOR_SPLIT:-}"
FALLBACK_MODEL="${FALLBACK_MODEL:-qwen3.5:122b}"
WARMUP_PROMPT="${WARMUP_PROMPT:-Explique en trois phrases le rôle de la VRAM pendant l'inférence d'un modèle de langage.}"

# Cette sortie est montrée dans la vidéo : les chemins affichés sont raccourcis
# en « ~ », conformément aux règles de publication du README.
display_path() { printf '%s' "${1/#"${HOME}"/\~}"; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
code_dir="$(cd -- "${script_dir}/.." && pwd)"
prompt_file="${PROMPT_FILE:-${code_dir}/examples/proof-prompt-reseau-en.txt}"
artifact_root="${ARTIFACT_ROOT:-${code_dir}/proof-artifacts}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${artifact_root}/${timestamp}-${MODE}"
server_pid=""
network_may_be_off=0

cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${network_may_be_off}" == "1" ]]; then
    echo
    echo "RAPPEL: restaurer le réseau avec: nmcli networking on"
  fi
}
trap cleanup EXIT

mkdir -p "${run_dir}"

if [[ "${HOST}" != "127.0.0.1" ]]; then
  echo "ERREUR: cette preuve refuse toute écoute hors localhost (HOST=${HOST})." >&2
  exit 1
fi

for required_command in amd-smi curl free ip jq rocminfo sed; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERREUR: commande requise absente: ${required_command}" >&2
    exit 1
  fi
done

if [[ ! -r "${prompt_file}" ]]; then
  echo "ERREUR: prompt introuvable: ${prompt_file}" >&2
  exit 1
fi
prompt="$(<"${prompt_file}")"

stream_hy3() {
  local label="$1"
  local request_prompt="$2"
  local reasoning_effort="${3:-no_think}"
  local request_file="${run_dir}/${label}-request.json"
  local response_file="${run_dir}/${label}-response.sse"

  jq -nc \
    --arg prompt "${request_prompt}" \
    --arg reasoning_effort "${reasoning_effort}" \
    '{
      model:"hy3",
      messages:[{role:"user",content:$prompt}],
      max_tokens:1024,
      temperature:0.9,
      top_p:1.0,
      chat_template_kwargs:{reasoning_effort:$reasoning_effort},
      stream:true
    }' > "${request_file}"

  echo
  echo ">>> ${label}"
  curl -fsS -N --noproxy '*' \
    -H 'Content-Type: application/json' \
    --data-binary "@${request_file}" \
    "http://${HOST}:${PORT}/v1/chat/completions" \
    | tee "${response_file}" \
    | sed -u -n 's/^data: \({.*\)$/\1/p' \
    | jq --unbuffered -jr '.choices[0].delta.reasoning_content // .choices[0].delta.content // empty'
  echo
}

stream_fallback() {
  local label="$1"
  local request_prompt="$2"
  local request_file="${run_dir}/${label}-request.json"
  local response_file="${run_dir}/${label}-response.jsonl"

  jq -nc \
    --arg model "${FALLBACK_MODEL}" \
    --arg prompt "${request_prompt}" \
    --argjson num_ctx "${CONTEXT_LENGTH}" \
    '{model:$model,prompt:$prompt,stream:true,think:false,keep_alive:"30m",options:{num_ctx:$num_ctx}}' \
    > "${request_file}"

  echo
  echo ">>> ${label}"
  curl -fsS -N --noproxy '*' \
    -H 'Content-Type: application/json' \
    --data-binary "@${request_file}" \
    http://127.0.0.1:11434/api/generate \
    | tee "${response_file}" \
    | jq --unbuffered -jr '.response // empty'
  echo
}

start_hy3() {
  local llama_server="${LLAMA_CPP_DIR}/build/bin/llama-server"
  if [[ ! -x "${llama_server}" ]]; then
    echo "ERREUR: llama-server introuvable: $(display_path "${llama_server}")" >&2
    exit 2
  fi
  if [[ ! -s "${MODEL_PATH}" ]]; then
    echo "ERREUR: modèle introuvable: $(display_path "${MODEL_PATH}")" >&2
    exit 2
  fi

  # Le port doit être libre AVANT de démarrer. Si un autre serveur l'occupe
  # déjà — un llama-server lancé pour un autre projet, par exemple — le nôtre
  # meurt sur « address already in use », mais la boucle d'attente ci-dessous
  # verrait répondre l'intrus et continuerait : le gate mesurerait alors un
  # autre modèle, et l'overlay de la vidéo annoncerait Hy3 à tort.
  if curl -fsS --noproxy '*' --max-time 2 "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
    echo "ERREUR: un service répond déjà sur ${HOST}:${PORT}." >&2
    echo "Arrêter ce service avant la preuve : la mesure porterait sur le mauvais modèle." >&2
    exit 2
  fi

  server_args=(
    --host "${HOST}"
    --port "${PORT}"
    --model "${MODEL_PATH}"
    --alias hy3
    --ctx-size "${CONTEXT_LENGTH}"
    --n-gpu-layers all
    --split-mode layer
    --parallel 1
    --cache-type-k q8_0
    --cache-type-v q8_0
    --flash-attn on
    --spec-type draft-mtp
    --spec-draft-n-max 3
    --spec-draft-n-min 1
    --cache-type-k-draft q8_0
    --cache-type-v-draft q8_0
    --jinja
    --perf
    --offline
  )
  if [[ -n "${TENSOR_SPLIT}" ]]; then
    server_args+=(--tensor-split "${TENSOR_SPLIT}")
  fi

  echo "Démarrage de llama-server..."
  # llama.cpp journalise le chemin absolu du modèle : filtré avant l'écran ET
  # avant le log, puisque les deux peuvent finir dans la vidéo ou le dépôt public.
  "${llama_server}" "${server_args[@]}" \
    > >(sed -u "s|${HOME}|~|g" | tee "${run_dir}/llama-server.log") 2>&1 &
  server_pid="$!"

  for _ in $(seq 1 600); do
    if curl -fsS --noproxy '*' --max-time 2 "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
      return
    fi
    if ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "ERREUR: llama-server s'est arrêté pendant le chargement." >&2
      exit 3
    fi
    sleep 1
  done
  echo "ERREUR: llama-server n'est pas prêt après 10 minutes." >&2
  exit 3
}

{
  echo "UTC: $(date -u --iso-8601=seconds)"
  echo "MODE: ${MODE}"
  echo "KERNEL: $(uname -r)"
  echo "OS: $(. /etc/os-release; printf '%s %s' "${NAME}" "${VERSION_ID}")"
  echo "MEMORY:"
  free -h
  echo
  # Seuls render et video comptent. « id » afficherait le nom d'utilisateur, or
  # cette sortie est filmée : le détail complet part dans l'artefact plus bas.
  echo "GROUPS:"
  for g in render video; do
    if id -nG | tr ' ' '\n' | grep -qx "${g}"; then
      printf '  %-8s présent\n' "${g}"
    else
      printf '  %-8s ABSENT\n' "${g}"
    fi
  done
  echo
  echo "ROCMINFO GPU AGENTS:"
  rocminfo 2>/dev/null | grep -E '^[[:space:]]*(Name:|Uuid:|Marketing Name:)' || true
  echo
  echo "AMD SMI:"
  amd-smi list || true
} | tee "${run_dir}/environment.txt"

# Détail d'identité complet : archivé pour la traçabilité, jamais affiché.
{ echo; echo "ID COMPLET (hors écran):"; id; } >> "${run_dir}/environment.txt"

if [[ "${MODE}" == "hy3" ]]; then
  start_hy3
  printf 'MODEL_PATH: %s\n' "$(display_path "${MODEL_PATH}")" | tee -a "${run_dir}/environment.txt"
  git -C "${LLAMA_CPP_DIR}" rev-parse HEAD | sed 's/^/LLAMA_CPP_COMMIT: /' \
    | tee -a "${run_dir}/environment.txt"

  set +e
  API_URL="http://${HOST}:${PORT}" \
    MIN_TOKENS_PER_SECOND="${MIN_TOKENS_PER_SECOND}" \
    ARTIFACT_RUN_DIR="${run_dir}" \
    "${script_dir}/04-speed-gate.sh"
  gate_status="$?"
  set -e
  if [[ "${gate_status}" -ne 0 ]]; then
    exit "${gate_status}"
  fi
  stream_command="stream_hy3"
  local_health_url="http://${HOST}:${PORT}/health"
elif [[ "${MODE}" == "fallback" ]]; then
  for required_command in ollama systemctl; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
      echo "ERREUR: commande requise absente pour le fallback: ${required_command}" >&2
      exit 1
    fi
  done
  if ! systemctl is-active --quiet ollama || ! ollama show "${FALLBACK_MODEL}" >/dev/null 2>&1; then
    echo "ERREUR: fallback Ollama indisponible. Exécuter ./scripts/03-prepare-models.sh." >&2
    exit 2
  fi
  stream_command="stream_fallback"
  local_health_url="http://127.0.0.1:11434/api/version"
  printf 'FALLBACK_MODEL: %s\n' "${FALLBACK_MODEL}" | tee -a "${run_dir}/environment.txt"
else
  echo "ERREUR: MODE doit valoir hy3 ou fallback." >&2
  exit 2
fi

echo
echo "Ouvrir dans un autre terminal: amd-smi monitor --watch 1"
read -r -p "Démarrer OBS, puis appuyer sur Entrée pour la première requête. "

"${stream_command}" "01-online" "${WARMUP_PROMPT}" "no_think"
amd-smi metric --mem-usage --usage 2>&1 | tee "${run_dir}/01-online-amd-smi.txt" || true

echo
echo "Couper maintenant Internet depuis une session locale: nmcli networking off"
read -r -p "Quand l'état hors ligne est visible, appuyer sur Entrée. "
network_may_be_off=1

{
  echo "UTC: $(date -u --iso-8601=seconds)"
  echo
  echo "NETWORK STATE:"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli networking
    nmcli -t -f DEVICE,TYPE,STATE device status
  else
    ip -brief link
  fi
} | tee "${run_dir}/02-network-off.txt"

if curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "ERREUR: Internet est encore joignable. La preuve hors ligne est refusée." >&2
  exit 4
fi

curl -fsS --noproxy '*' --max-time 3 "${local_health_url}" \
  | tee "${run_dir}/02-local-api-still-up.txt"
echo

# « no_think » et non « high » : mesuré le 2026-08-15, un raisonnement complet
# ne converge pas avant 2 048 tokens et la réponse reste vide à l'écran. En
# réponse directe, Hy3 rend les six points attendus en 638 tokens et 34 s.
"${stream_command}" "03-offline" "${prompt}" "no_think"
amd-smi metric --mem-usage --usage 2>&1 | tee "${run_dir}/03-offline-amd-smi.txt" || true

echo
echo "Preuve terminée. Logs: $(display_path "${run_dir}")"
echo "Restaurer le réseau: nmcli networking on"
echo "Compléter ensuite: ${code_dir}/local-proof-log.md"
