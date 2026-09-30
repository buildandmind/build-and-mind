#!/usr/bin/env bash
set -Eeuo pipefail

# Lit sur son entrée standard le flux SSE d'un serveur compatible OpenAI et
# n'affiche que le texte généré, au fur et à mesure.
#
# Ce script existe pour une raison de tournage : la règle 4.8 du playbook
# éditorial interdit les one-liners dans une démonstration filmée. Sans lui,
# la commande de preuve serait un enchaînement `curl | sed | jq` que personne
# ne peut lire à l'écran. Ici, l'intention est dans le nom du script.
#
# Usage :
#   curl -sN ... | ./scripts/06-read-sse-stream.sh

for required_command in jq sed; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERREUR: commande requise absente: ${required_command}" >&2
    exit 1
  fi
done

# 1. ne garder que les lignes de données, sans leur préfixe « data: »
# 2. en extraire le fragment de texte, s'il y en a un
sed -u -n 's/^data: \({.*\)$/\1/p' \
  | jq --unbuffered -jr '.choices[0].delta.content // empty'

echo
