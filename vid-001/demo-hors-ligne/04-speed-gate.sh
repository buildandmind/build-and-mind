#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="${API_URL:-http://127.0.0.1:8090}"
MIN_TOKENS_PER_SECOND="${MIN_TOKENS_PER_SECOND:-15}"
ARTIFACT_RUN_DIR="${ARTIFACT_RUN_DIR:-}"
BENCHMARK_PROMPT="${BENCHMARK_PROMPT:-Rédige une analyse technique continue d'au moins quatre cents mots sur les compromis entre VRAM, bande passante mémoire et parallélisme de modèles. Ne conclus pas avant d'avoir couvert les trois sujets.}"

for required_command in awk curl jq sort; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERREUR: commande requise absente: ${required_command}" >&2
    exit 1
  fi
done

if [[ -z "${ARTIFACT_RUN_DIR}" ]]; then
  echo "ERREUR: ARTIFACT_RUN_DIR doit pointer vers le dossier de preuve courant." >&2
  exit 1
fi
mkdir -p "${ARTIFACT_RUN_DIR}"

if ! curl -fsS --noproxy '*' --max-time 5 "${API_URL}/health" >/dev/null; then
  echo "ERREUR: llama-server ne répond pas sur ${API_URL}." >&2
  exit 2
fi

request() {
  local label="$1"
  local max_tokens="$2"
  local request_file="${ARTIFACT_RUN_DIR}/${label}-request.json"
  local response_file="${ARTIFACT_RUN_DIR}/${label}-response.json"

  jq -nc \
    --arg prompt "${BENCHMARK_PROMPT}" \
    --argjson max_tokens "${max_tokens}" \
    '{
      model:"hy3",
      messages:[{role:"user",content:$prompt}],
      max_tokens:$max_tokens,
      temperature:0.9,
      top_p:1.0,
      seed:42,
      chat_template_kwargs:{reasoning_effort:"no_think"},
      stream:false
    }' > "${request_file}"

  curl -fsS --noproxy '*' \
    -H 'Content-Type: application/json' \
    --data-binary "@${request_file}" \
    "${API_URL}/v1/chat/completions" > "${response_file}"

  jq -er '.timings.predicted_per_second | numbers' "${response_file}"
}

echo "Échauffement du modèle..."
request "gate-warmup" 64 >/dev/null

speeds=()
for run in 1 2 3; do
  speed="$(request "gate-run-${run}" 256)"
  speeds+=("${speed}")
  printf 'Run %d: %s tok/s\n' "${run}" "${speed}"
done

mapfile -t sorted_speeds < <(printf '%s\n' "${speeds[@]}" | sort -n)
median="${sorted_speeds[1]}"

jq -n \
  --argjson run_1 "${speeds[0]}" \
  --argjson run_2 "${speeds[1]}" \
  --argjson run_3 "${speeds[2]}" \
  --argjson median "${median}" \
  --argjson threshold "${MIN_TOKENS_PER_SECOND}" \
  '{
    protocol:"1 warmup + 3 runs, single server slot, max 256 generated tokens",
    predicted_tokens_per_second:[$run_1,$run_2,$run_3],
    median:$median,
    threshold:$threshold,
    pass:($median >= $threshold)
  }' | tee "${ARTIFACT_RUN_DIR}/speed-gate-summary.json"

if ! awk -v median="${median}" -v threshold="${MIN_TOKENS_PER_SECOND}" \
  'BEGIN { exit !(median >= threshold) }'; then
  echo "GATE REFUSÉ: médiane ${median} tok/s < ${MIN_TOKENS_PER_SECOND} tok/s." >&2
  echo "Basculer sur: MODE=fallback ./scripts/05-proof-demo.sh" >&2
  exit 10
fi

echo "GATE VALIDÉ: médiane ${median} tok/s >= ${MIN_TOKENS_PER_SECOND} tok/s."
