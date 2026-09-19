# La démo hors ligne

Six scripts, à lancer dans l'ordre depuis ce dossier, avec un compte normal qui a `sudo`. Ne
lancez pas un script entier avec `sudo` : chacun demande le mot de passe quand il en a besoin.

| Script | Ce qu'il fait |
|---|---|
| `01-preflight.sh` | regarde ce qui est là (système, cartes, ROCm, llama.cpp) sans rien modifier |
| `02-install-stack.sh` | installe ROCm, compile llama.cpp pour AMD, prépare le téléchargement des modèles |
| `03-prepare-models.sh` | télécharge le modèle (91,8 Go) et, si vous le voulez, un modèle de repli |
| `04-speed-gate.sh` | trois générations, une médiane, un verdict : assez rapide ou pas |
| `05-proof-demo.sh` | démarre le serveur, mesure, pose la question, coupe Internet, repose la question |
| `06-read-sse-stream.sh` | lit le flux de réponse du serveur, mot par mot |

Configuration : copiez `hy3-major.env.example` en `hy3-major.env`, ajustez les chemins, puis
`set -a; source hy3-major.env; set +a`. Aucun secret n'y entre.

## Avant de commencer

- Linux natif. Sous WSL, les cartes ne sont pas vues séparément : le premier script refuse.
- Ubuntu 26.04 fournit ROCm 7.1 dans ses dépôts, sans redémarrage. Sur 24.04, le script passe par
  le dépôt AMD et vous préviendra qu'un redémarrage est nécessaire.
- Le modèle de la vidéo demande environ 92 Go de mémoire graphique. Avec moins, prenez un modèle
  plus petit dans `03-prepare-models.sh` : la méthode ne change pas, seuls les chiffres changent.
- Prévoyez 100 Go libres sur le disque pour le modèle, 210 Go si vous voulez aussi le repli.
- `05-proof-demo.sh` coupe le réseau de la machine (`nmcli networking off`) le temps de la seconde
  question, puis le rétablit. Ne le lancez pas depuis une session SSH.

## Ce que mesure le test de vitesse

`04-speed-gate.sh` envoie trois fois le même prompt, relève les tokens par seconde de chaque
génération et garde la médiane. Dans la vidéo, le seuil était de 15 tokens par seconde ; la médiane
mesurée le 15 août 2026 était de 18,83. Le fichier `speed-gate-summary.json` garde les trois valeurs.

Les prompts d'exemple (`proof-prompt-*.txt`) décrivent un réseau d'entreprise inventé : ni le nôtre,
ni celui d'un client.
