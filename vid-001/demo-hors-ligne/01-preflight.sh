#!/usr/bin/env bash
set -Eeuo pipefail

# Vérifications non destructives. Ce script n'installe et ne modifie rien.
# Il signale ce qui manque ; il ne refuse que ce qui rend la preuve impossible.

warnings=0

# La sortie de ce script est montrée dans la vidéo. Les chemins affichés sont
# donc raccourcis en « ~ » : les règles de publication du README interdisent
# qu'un nom d'utilisateur ou un chemin privé apparaisse à l'image.
display_path() { printf '%s' "${1/#"${HOME}"/\~}"; }

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release not found." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

echo "== System =="
printf 'OS: %s %s (%s)\n' "${NAME:-unknown}" "${VERSION_ID:-unknown}" "${VERSION_CODENAME:-unknown}"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Kernel: %s\n' "$(uname -r)"

# La preuve multi-GPU exige un Linux natif : sous WSL, les quatre cartes ne sont
# pas exposées séparément et la télémétrie filmée ne voudrait rien dire.
if grep -qi microsoft /proc/version; then
  echo "ERROR: WSL detected. The multi-GPU proof must run on native Linux." >&2
  exit 2
fi

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "WARNING: procedure written for Ubuntu. Detected distribution: ${ID:-unknown}." >&2
  echo "Package names and the ROCm repository will need adjusting." >&2
  warnings=$((warnings + 1))
fi

echo
echo "== PCIe GPUs =="
if command -v lspci >/dev/null 2>&1; then
  lspci -nn | grep -Ei 'VGA compatible controller|Display controller|3D controller' || true
  gpu_count="$(lspci -nn | grep -Eci 'VGA compatible controller|Display controller|3D controller' || true)"
  printf 'GPUs seen on the bus: %s\n' "${gpu_count}"
else
  echo "lspci missing (package pciutils)."
  warnings=$((warnings + 1))
fi

echo
echo "== Compute driver (KFD) =="
# /dev/kfd est l'interface de calcul du pilote amdgpu. S'il est present et que
# amd-smi liste les cartes, la partie noyau est déjà opérationnelle : aucune
# installation de pilote n'est alors nécessaire.
if [[ -e /dev/kfd ]]; then
  echo "/dev/kfd present: the kernel compute layer is active."
else
  echo "/dev/kfd missing: the AMD compute driver is not loaded."
  warnings=$((warnings + 1))
fi

echo
echo "== User groups =="
# Seuls 'render' et 'video' comptent ici. La liste complète contient le groupe
# personnel, qui porte le nom de l'utilisateur — à ne pas afficher à l'image.
for g in render video; do
  if id -nG | tr ' ' '\n' | grep -qx "${g}"; then
    printf '%-8s present\n' "${g}"
  else
    printf '%-8s MISSING\n' "${g}"
  fi
done
if ! id -nG | tr ' ' '\n' | grep -qx render; then
  echo "WARNING: user is not in group 'render'." >&2
  warnings=$((warnings + 1))
fi

echo
echo "== ROCm =="
if command -v rocminfo >/dev/null 2>&1; then
  rocminfo 2>/dev/null | grep -E '^[[:space:]]*(Name:|Uuid:|Marketing Name:)' || true
  echo
  echo "GPU architectures detected:"
  rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | sort | uniq -c || true
else
  echo "rocminfo missing (package rocminfo)."
  warnings=$((warnings + 1))
fi

echo
echo "== AMD SMI =="
if command -v amd-smi >/dev/null 2>&1; then
  amd-smi version || true
  amd-smi list || true
else
  echo "amd-smi missing."
  warnings=$((warnings + 1))
fi

echo
echo "== llama.cpp / HIP =="
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${HOME}/.local/src/llama.cpp-vid001}"
llama_server="${LLAMA_CPP_DIR}/build/bin/llama-server"
if [[ -x "${llama_server}" ]]; then
  printf 'Repository: %s\n' "$(display_path "${LLAMA_CPP_DIR}")"
  git -C "${LLAMA_CPP_DIR}" rev-parse --short HEAD 2>/dev/null || true
  "${llama_server}" --version || true
  "${llama_server}" --list-devices || true
else
  echo "llama-server missing: $(display_path "${llama_server}")"
  warnings=$((warnings + 1))
fi

echo
echo "== Models =="
MODEL_PATH="${MODEL_PATH:-${HOME}/models/hy3/Hy3-IQ1_M-mtp.gguf}"
if [[ -s "${MODEL_PATH}" ]]; then
  # ls -lh afficherait aussi le propriétaire et le groupe, donc le nom d'utilisateur.
  printf '%s  %s\n' "$(du -h "${MODEL_PATH}" | cut -f1)" "$(display_path "${MODEL_PATH}")"
else
  echo "Main model missing: $(display_path "${MODEL_PATH}")"
  warnings=$((warnings + 1))
fi

echo
echo "== Ollama (fallback) =="
if command -v ollama >/dev/null 2>&1; then
  ollama --version || true
  systemctl is-active ollama || true
  curl -fsS --max-time 3 http://127.0.0.1:11434/api/version || true
  echo
  ollama ls || true
else
  echo "ollama not installed."
  warnings=$((warnings + 1))
fi

echo
if (( warnings == 0 )); then
  echo "Preflight done: nothing missing."
else
  echo "Preflight done: ${warnings} item(s) to address, listed above."
  echo "Before install, these gaps are expected: ./scripts/02-install-stack.sh covers them."
fi
echo "Visually confirm that the four expected GPUs appear."
