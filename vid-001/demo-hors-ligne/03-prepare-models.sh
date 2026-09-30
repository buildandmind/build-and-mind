#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_REPO="${MODEL_REPO:-AngelSlim/Hy3-GGUF}"
MODEL_FILE="${MODEL_FILE:-Hy3-IQ1_M-mtp.gguf}"
MODEL_DIR="${MODEL_DIR:-${HOME}/models/hy3}"
HF_BIN="${HF_BIN:-${HOME}/.local/share/vid001-hf-venv/bin/hf}"
FALLBACK_MODEL="${FALLBACK_MODEL:-qwen3.5:122b}"
PULL_FALLBACK="${PULL_FALLBACK:-1}"
REQUIRED_GIB="${REQUIRED_GIB:-210}"

if [[ ! -x "${HF_BIN}" ]]; then
  echo "ERREUR: CLI Hugging Face introuvable: ${HF_BIN}" >&2
  echo "Exécuter d'abord ./scripts/02-install-stack.sh." >&2
  exit 1
fi

mkdir -p "${MODEL_DIR}"
available_kib="$(df -Pk "${MODEL_DIR}" | awk 'NR==2 {print $4}')"
available_gib="$((available_kib / 1024 / 1024))"

echo "Espace disponible sur le volume des modèles: ${available_gib} GiB"
if (( available_gib < REQUIRED_GIB )); then
  echo "ERREUR: au moins ${REQUIRED_GIB} GiB libres sont demandés." >&2
  echo "Hy3 MTP fait environ 91,8 Go et le fallback Qwen environ 81 Go." >&2
  exit 2
fi

echo "Téléchargement du modèle principal: ${MODEL_REPO}/${MODEL_FILE}"
"${HF_BIN}" download "${MODEL_REPO}" "${MODEL_FILE}" --local-dir "${MODEL_DIR}"

model_path="${MODEL_DIR}/${MODEL_FILE}"
if [[ ! -s "${model_path}" ]]; then
  echo "ERREUR: fichier absent ou vide après téléchargement: ${model_path}" >&2
  exit 3
fi

if [[ "${PULL_FALLBACK}" == "1" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "ERREUR: Ollama est requis pour préparer le fallback." >&2
    exit 4
  fi
  if ! systemctl is-active --quiet ollama; then
    echo "ERREUR: le service Ollama n'est pas actif." >&2
    exit 4
  fi
  echo "Téléchargement du fallback de production: ${FALLBACK_MODEL}"
  ollama pull "${FALLBACK_MODEL}"
fi

echo
ls -lh "${model_path}"
if [[ "${PULL_FALLBACK}" == "1" ]]; then
  ollama ls
fi
echo
echo "Les deux chemins de tournage sont prêts."
