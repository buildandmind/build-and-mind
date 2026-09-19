#!/usr/bin/env bash
# trier-photos.sh — la tache de nuit : un modele de vision local regarde un
# dossier de photos, une par une, et renomme chaque fichier par ce qu'il voit.
#
#   ./trier-photos.sh /srv/photos
#
# C'est le travail filme au plan T10-c de VID-001 (« pendant que je dors ») :
# un lot de quarante photos de montage sorties d'un appareil, avec des noms
# d'appareil (DSC_3678.jpg), qu'aucun humain n'a envie de renommer a la main.
#
# Comment ca marche, en trois lignes :
#   1. chaque photo est envoyee au modele de vision qui tourne sur la machine
#      (llama.cpp, via la passerelle locale) ;
#   2. le modele rend une description courte et un nom de fichier ;
#   3. le fichier est renomme, et le couple ancien/nouveau nom est ecrit dans
#      un journal CSV a cote.
#
# Rien ne sort de la machine : l'adresse appelee est la boucle locale.
set -Eeuo pipefail

DOSSIER="${1:-/srv/photos}"
PASSERELLE="${PASSERELLE:-http://127.0.0.1:20000/v1/chat/completions}"
MODELE="${MODELE:-qwen3-vl}"
JOURNAL="${JOURNAL:-${DOSSIER}/journal-tri.csv}"
# Apercu de la photo directement dans le terminal (paquet « chafa »).
# Sans lui, le script marche pareil : il n'affiche que le nom du fichier.
APERCU_LARGEUR="${APERCU_LARGEUR:-52}"
APERCU_HAUTEUR="${APERCU_HAUTEUR:-18}"

CONSIGNE='Decris cette photo en une phrase courte en francais (12 mots maximum),
puis propose un nom de fichier en francais, en minuscules, les mots separes par
des tirets, sans extension. Reponds exactement dans ce format :
DESCRIPTION: ...
NOM: ...'

# --- couleurs (rien de fabrique : ce sont celles du terminal) ---------------
GRIS=$'\e[90m'; ORANGE=$'\e[33m'; CYAN=$'\e[36m'; VERT=$'\e[32m'; RAZ=$'\e[0m'

mapfile -t PHOTOS < <(find "${DOSSIER}" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)
TOTAL="${#PHOTOS[@]}"
[[ "${TOTAL}" -gt 0 ]] || { echo "aucune photo dans ${DOSSIER}"; exit 1; }

[[ -f "${JOURNAL}" ]] || echo "nom_origine,nom_final,description" > "${JOURNAL}"

printf '%s\n' "${GRIS}tri de ${TOTAL} photos — modele de vision local${RAZ}"
echo

fait=0
for photo in "${PHOTOS[@]}"; do
  fait=$((fait + 1))
  origine="$(basename "${photo}")"

  # Le compteur d'abord : c'est lui qui dit que le travail avance tout seul.
  printf '%s\n' "${ORANGE}[${fait}/${TOTAL}]${RAZ} ${origine}"

  # L'apercu montre que le modele recoit bien une image, pas un nom de fichier.
  if command -v chafa >/dev/null 2>&1; then
    # --format symbols : des caracteres, pas du sixel. Les terminaux servis
    # dans une page (xterm.js) ne dessinent pas le sixel et afficheraient a la
    # place un pave de « + ». Les symboles, eux, s'affichent partout.
    # --symbols vhalf : uniquement les demi-blocs. Deux couleurs par cellule,
    # donc deux fois plus de definition en hauteur, et une image qui se lit
    # comme une photo — pas comme une soupe de lettres.
    chafa --format symbols --symbols vhalf --colors full --animate off \
      --size "${APERCU_LARGEUR}x${APERCU_HAUTEUR}" "${photo}" || true
  fi

  # --- l'appel au modele ----------------------------------------------------
  # L'image part en base64 dans le corps de la requete, format OpenAI.
  reponse="$(
    python3 - "${photo}" "${MODELE}" "${CONSIGNE}" "${PASSERELLE}" <<'PY'
import base64, json, sys, urllib.request

photo, modele, consigne, passerelle = sys.argv[1:5]
image = base64.b64encode(open(photo, "rb").read()).decode()
corps = {
    "model": modele,
    "max_tokens": 90,
    "temperature": 0.3,
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": consigne},
        {"type": "image_url",
         "image_url": {"url": "data:image/jpeg;base64," + image}},
    ]}],
}
requete = urllib.request.Request(
    passerelle, data=json.dumps(corps).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(requete, timeout=300) as r:
    print(json.load(r)["choices"][0]["message"]["content"].strip())
PY
  )" || { printf '%s\n\n' "  ${GRIS}photo ignoree (le modele n'a pas repondu)${RAZ}"; continue; }

  description="$(sed -n 's/^DESCRIPTION:[[:space:]]*//p' <<<"${reponse}" | head -1)"
  nom="$(sed -n 's/^NOM:[[:space:]]*//p' <<<"${reponse}" | head -1)"

  # Garde-fou : on ne laisse passer qu'un nom de fichier sage.
  nom="$(tr '[:upper:]' '[:lower:]' <<<"${nom}" | tr -cd 'a-z0-9-' | cut -c1-60)"
  [[ -n "${nom}" ]] || nom="photo-${fait}"

  final="${nom}.jpg"
  suffixe=2
  while [[ -e "${DOSSIER}/${final}" ]]; do
    final="${nom}-${suffixe}.jpg"; suffixe=$((suffixe + 1))
  done

  printf '        %s\n' "${CYAN}${description}${RAZ}"
  printf '        %s\n\n' "${VERT}-> ${final}${RAZ}"

  mv -- "${photo}" "${DOSSIER}/${final}"
  printf '%s,%s,"%s"\n' "${origine}" "${final}" "${description//\"/\'\'}" >> "${JOURNAL}"
done

printf '%s\n' "${VERT}${fait} photos triees. Journal : $(basename "${JOURNAL}")${RAZ}"
