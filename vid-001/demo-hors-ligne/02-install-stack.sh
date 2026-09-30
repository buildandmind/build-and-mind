#!/usr/bin/env bash
set -Eeuo pipefail

# Installe la pile d'inférence : ROCm, llama.cpp/HIP, CLI Hugging Face, Ollama.
#
# Deux chemins possibles pour ROCm, choisis automatiquement :
#   1. les paquets de la distribution, quand elle fournit une version assez
#      récente pour les GPU visés (cas d'Ubuntu 26.04, qui livre ROCm 7.1) ;
#   2. le dépôt officiel AMD, sinon (cas d'Ubuntu 24.04, ROCm trop ancien côté
#      distribution) — ce chemin remplace le pilote et impose un redémarrage.
#
# Le pilote n'est jamais réinstallé si la couche de calcul du noyau fonctionne
# déjà : c'est l'étape la plus risquée du protocole, on l'évite quand on peut.

GPU_TARGETS="${GPU_TARGETS:-gfx1201}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${HOME}/.local/src/llama.cpp-vid001}"
HF_VENV="${HF_VENV:-${HOME}/.local/share/vid001-hf-venv}"
HY3_SUPPORT_COMMIT="${HY3_SUPPORT_COMMIT:-505b1ed}"
MIN_ROCM_VERSION="${MIN_ROCM_VERSION:-7.0}"
ROCM_VERSION="${ROCM_VERSION:-7.2.1}"
ROCM_PACKAGE_BUILD="${ROCM_PACKAGE_BUILD:-70201}"
INSTALL_OLLAMA="${INSTALL_OLLAMA:-1}"

temp_dir=""
ollama_installer=""
reboot_required=0
rocwmma_available=0

cleanup() {
  if [[ -n "${temp_dir}" && "${temp_dir}" == /tmp/vid001-rocm.* ]]; then
    rm -rf -- "${temp_dir}"
  fi
  if [[ -n "${ollama_installer}" && "${ollama_installer}" == /tmp/vid001-ollama-install.*.sh ]]; then
    rm -f -- "${ollama_installer}"
  fi
}
trap cleanup EXIT

if [[ "${EUID}" -eq 0 ]]; then
  echo "ERREUR: lancer ce script avec un utilisateur normal, sans préfixer la commande par sudo." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "ERREUR: ce script est écrit pour Ubuntu. Distribution détectée: ${ID:-inconnue}." >&2
  echo "Installer ROCm selon la documentation AMD, puis reprendre à l'étape de compilation." >&2
  exit 2
fi

if grep -qi microsoft /proc/version; then
  echo "ERREUR: WSL détecté. Utiliser Linux natif pour le multi-GPU." >&2
  exit 2
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERREUR: architecture non prise en charge: $(uname -m)." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Choix de la source ROCm
# ---------------------------------------------------------------------------

distro_rocm_candidate="$(apt-cache policy rocminfo 2>/dev/null | awk '/Candidat[e]?:/ {print $2; exit}')"
rocm_source="amd-repo"

if [[ -n "${distro_rocm_candidate}" && "${distro_rocm_candidate}" != "(none)" ]] \
  && dpkg --compare-versions "${distro_rocm_candidate}" ge "${MIN_ROCM_VERSION}"; then
  rocm_source="distro"
fi

# Le pilote de calcul est-il déjà opérationnel ?
kfd_ready=0
if [[ -e /dev/kfd ]] && command -v amd-smi >/dev/null 2>&1 && amd-smi list >/dev/null 2>&1; then
  kfd_ready=1
fi

echo "Distribution      : ${NAME} ${VERSION_ID} (${VERSION_CODENAME:-?})"
echo "Noyau             : $(uname -r)"
echo "ROCm distribution : ${distro_rocm_candidate:-aucun}"
echo "Source ROCm       : ${rocm_source}"
if (( kfd_ready )); then
  echo "Pilote de calcul  : déjà opérationnel, aucune installation de pilote"
else
  echo "Pilote de calcul  : absent, il sera installé"
fi
echo "Cible GPU         : ${GPU_TARGETS}"
echo

if [[ "${rocm_source}" == "amd-repo" ]]; then
  case "${VERSION_CODENAME:-}" in
    jammy|noble) ;;
    *)
      echo "ERREUR: la distribution ne fournit pas ROCm >= ${MIN_ROCM_VERSION}," >&2
      echo "et AMD ne publie pas de paquets pour « ${VERSION_CODENAME:-inconnu} »." >&2
      echo "Vérifier la matrice de compatibilité AMD avant d'aller plus loin." >&2
      exit 3
      ;;
  esac
  echo "AVERTISSEMENT: le pilote GPU va être remplacé et un redémarrage sera nécessaire."
fi

read -r -p "Continuer ? [y/N] " answer
if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
  echo "Installation annulée."
  exit 0
fi

# ---------------------------------------------------------------------------
# Outils de compilation
# ---------------------------------------------------------------------------

sudo apt-get update
sudo apt-get install -y \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  git \
  jq \
  libcurl4-openssl-dev \
  ninja-build \
  pciutils \
  python3-pip \
  python3-setuptools \
  python3-venv \
  python3-wheel \
  wget

# ---------------------------------------------------------------------------
# ROCm
# ---------------------------------------------------------------------------

if [[ "${rocm_source}" == "distro" ]]; then
  echo
  echo "Installation de ROCm depuis les dépôts de la distribution."
  sudo apt-get install -y rocm-dev rocminfo libhipblas-dev librocblas-dev

  if apt-cache policy librocwmma-dev 2>/dev/null | grep -q 'Candidat[e]\?: [0-9]'; then
    sudo apt-get install -y librocwmma-dev
    rocwmma_available=1
  fi
else
  installed_rocm=""
  if dpkg-query -W -f='${Version}' rocm-core >/dev/null 2>&1; then
    installed_rocm="$(dpkg-query -W -f='${Version}' rocm-core)"
  fi

  if [[ -n "${installed_rocm}" && "${installed_rocm}" != "${ROCM_VERSION}"* ]]; then
    echo "ERREUR: ROCm ${installed_rocm} est déjà installé." >&2
    echo "AMD déconseille les upgrades in-place. Désinstaller proprement, redémarrer, puis relancer." >&2
    exit 3
  fi

  if [[ -z "${installed_rocm}" ]]; then
    rocm_package="amdgpu-install_${ROCM_VERSION}.${ROCM_PACKAGE_BUILD}-1_all.deb"
    rocm_url="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${VERSION_CODENAME}/${rocm_package}"
    temp_dir="$(mktemp -d /tmp/vid001-rocm.XXXXXX)"
    echo "Téléchargement de ${rocm_url}"
    wget -O "${temp_dir}/${rocm_package}" "${rocm_url}"
    sudo apt-get install -y "${temp_dir}/${rocm_package}"

    if (( kfd_ready )); then
      # Le pilote fonctionne déjà : on installe uniquement la pile de calcul.
      sudo amdgpu-install -y --usecase=rocm --no-dkms
    else
      sudo amdgpu-install -y --usecase=graphics,rocm
      reboot_required=1
    fi
  else
    echo "ROCm ${installed_rocm} est déjà présent : installation ROCm ignorée."
  fi

  if sudo apt-get install -y rocwmma-dev; then
    rocwmma_available=1
  fi
fi

sudo usermod -a -G render,video "${USER}"

if ! command -v rocminfo >/dev/null 2>&1; then
  echo "ERREUR: rocminfo reste introuvable après installation." >&2
  exit 4
fi

echo
echo "Architectures GPU vues par ROCm :"
rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | sort | uniq -c || true

if ! rocminfo 2>/dev/null | grep -q "${GPU_TARGETS}"; then
  echo "AVERTISSEMENT: la cible ${GPU_TARGETS} n'apparaît pas dans rocminfo." >&2
  echo "Ajuster GPU_TARGETS avant de compiler, sinon le binaire ne servira pas les GPU." >&2
fi

# ---------------------------------------------------------------------------
# llama.cpp
# ---------------------------------------------------------------------------

mkdir -p "$(dirname -- "${LLAMA_CPP_DIR}")"
if [[ -e "${LLAMA_CPP_DIR}" && ! -d "${LLAMA_CPP_DIR}/.git" ]]; then
  echo "ERREUR: ${LLAMA_CPP_DIR} existe mais n'est pas un clone Git." >&2
  exit 4
fi

if [[ ! -d "${LLAMA_CPP_DIR}/.git" ]]; then
  git clone https://github.com/ggml-org/llama.cpp.git "${LLAMA_CPP_DIR}"
else
  if [[ -n "$(git -C "${LLAMA_CPP_DIR}" status --porcelain)" ]]; then
    echo "ERREUR: changements locaux détectés dans ${LLAMA_CPP_DIR}. Rien n'a été écrasé." >&2
    exit 4
  fi
  git -C "${LLAMA_CPP_DIR}" fetch --prune origin
  git -C "${LLAMA_CPP_DIR}" checkout --detach origin/master
fi

if ! git -C "${LLAMA_CPP_DIR}" merge-base --is-ancestor "${HY3_SUPPORT_COMMIT}" HEAD; then
  echo "ERREUR: le clone llama.cpp n'inclut pas le support Hy3 (${HY3_SUPPORT_COMMIT})." >&2
  exit 5
fi

# hipconfig sait où vit la chaîne de compilation HIP, que ROCm vienne de la
# distribution (/usr) ou du dépôt AMD (/opt/rocm).
if command -v hipconfig >/dev/null 2>&1; then
  HIPCXX="$(hipconfig -l 2>/dev/null)/clang"
  export HIPCXX

  # ROCM_PATH n'est exporté que si ce préfixe contient réellement les
  # bibliothèques de device. Avec le ROCm de la distribution, hipconfig renvoie
  # /usr, où il n'y a pas de amdgcn/bitcode : clang doit alors se rabattre sur
  # son propre resource dir. Exporter un ROCM_PATH sans bitcode casse la
  # détection et fait échouer la configuration CMake.
  rocm_prefix="$(hipconfig -R 2>/dev/null || true)"
  if [[ -n "${rocm_prefix}" && -d "${rocm_prefix}/amdgcn/bitcode" ]]; then
    export ROCM_PATH="${rocm_prefix}"
  else
    unset ROCM_PATH
  fi
fi

cmake_args=(
  -DGGML_HIP=ON
  -DGPU_TARGETS="${GPU_TARGETS}"
  -DCMAKE_BUILD_TYPE=Release
)
if (( rocwmma_available )); then
  cmake_args+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
  echo "rocWMMA disponible : Flash Attention accéléré activé."
else
  echo "rocWMMA indisponible : compilation sans Flash Attention rocWMMA."
fi

cmake -S "${LLAMA_CPP_DIR}" -B "${LLAMA_CPP_DIR}/build" -G Ninja "${cmake_args[@]}"
cmake --build "${LLAMA_CPP_DIR}/build" --config Release -j "$(nproc)"

# ---------------------------------------------------------------------------
# CLI Hugging Face
# ---------------------------------------------------------------------------

if [[ ! -x "${HF_VENV}/bin/hf" ]]; then
  python3 -m venv "${HF_VENV}"
  "${HF_VENV}/bin/python" -m pip install --upgrade pip huggingface_hub hf_xet
fi

# ---------------------------------------------------------------------------
# Ollama (chemin de repli uniquement)
# ---------------------------------------------------------------------------

if [[ "${INSTALL_OLLAMA}" == "1" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    ollama_installer="$(mktemp /tmp/vid001-ollama-install.XXXXXX.sh)"
    curl -fsSL https://ollama.com/install.sh -o "${ollama_installer}"
    sh "${ollama_installer}"
  fi

  if id ollama >/dev/null 2>&1; then
    sudo usermod -a -G render,video ollama
  fi

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  config_file="${script_dir}/../config/ollama-major.conf"

  sudo install -d -m 0755 /etc/systemd/system/ollama.service.d
  sudo install -m 0644 "${config_file}" /etc/systemd/system/ollama.service.d/major.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now ollama
fi

echo
echo "Installation terminée."
printf 'ROCm      : %s (source: %s)\n' "$(rocminfo --version 2>/dev/null | head -1 || echo 'voir rocminfo')" "${rocm_source}"
printf 'llama.cpp : %s (%s)\n' "${LLAMA_CPP_DIR}" "$(git -C "${LLAMA_CPP_DIR}" rev-parse --short HEAD)"
printf 'hf CLI    : %s/bin/hf\n' "${HF_VENV}"
echo

if (( reboot_required )); then
  echo "Étape obligatoire : sudo reboot"
  echo "Après le redémarrage : ./scripts/01-preflight.sh"
else
  echo "Aucun redémarrage nécessaire : le pilote n'a pas été remplacé."
  echo "Si l'appartenance aux groupes render/video vient d'être ajoutée, ouvrir une nouvelle session."
  echo "Étape suivante : ./scripts/01-preflight.sh"
fi
