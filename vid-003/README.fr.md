# Choisir une carte graphique pour une IA locale

Ce dossier accompagne la vidéo BUILD & MIND consacrée à la mémoire et aux
performances des cartes graphiques pour les modèles de texte locaux.

- [`resultats-principaux.csv`](resultats-principaux.csv) contient les médianes
  de nos essais avec Qwen3-14B Q4_K_M.
- [`resultats-quantification.csv`](resultats-quantification.csv) résume le test
  borné de deux quantifications d'un modèle de 27 milliards de paramètres.
- [`prompts/prompt-court.txt`](prompts/prompt-court.txt) est l'entrée courte
  employée pour mesurer la génération.
- [`prompts/questions-qualite.json`](prompts/questions-qualite.json) contient
  les cinq questions du test de quantification.

Les poids GGUF ne sont pas distribués ici. Téléchargez un modèle depuis une
source que vous jugez fiable et conservez son nom, sa quantification, sa taille
et son empreinte avec vos résultats. Les noms ci-dessous sont les identifiants
des fichiers réellement mesurés ; ce dossier n'attribue pas leur publication à
un dépôt amont non vérifié.

## Ce que nous avons comparé

Les mesures principales utilisent le même fichier `Qwen3-14B-Q4_K_M.gguf`
(9 001 752 960 octets, SHA-256
`500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`),
le même commit llama.cpp
`ece963f41b0b02d7a0d61436ae365762c073a4c8`, un contexte de 8192 tokens,
`-ngl 99`, `--split-mode layer`, `--parallel 1`, une température nulle et la
graine 1234. Une chauffe a été écartée, puis la médiane de trois passages a été
retenue. Dans le CSV, chaque valeur
`premier_token_s_un_passage_streame_separe` vient d'une requête streamée
supplémentaire unique. Ce n'est pas une médiane des trois passages mesurés.

Les installations diffèrent : la RTX 5070 Ti a été testée sous Windows 11 avec
CUDA, tandis que les cartes AMD ont été testées sous Ubuntu avec HIP/ROCm. Les
pilotes, les processeurs et les dates diffèrent aussi. Les chiffres comparent
donc ces installations complètes. Ils n'isolent pas CUDA, ROCm, la carte ou le
processeur comme cause unique.

| Palier | Carte(s) | Système et backend | Date |
|---|---|---|---|
| T1 | RTX 5070 Ti, 16 Go | Windows 11 build 26200, CUDA 13.3.33, pilote 596.36 | 10 septembre 2026 |
| T2 | RX 9070 XT, 16 Go | Ubuntu, HIP/ROCm 7.1 | 7 septembre 2026 |
| T3 | R9700, 32 Go | Ubuntu, HIP/ROCm 7.1 | 7 septembre 2026 |
| T4 | 3 × R9700 + 1 × RX 9070 XT, 112 Go cumulés | Ubuntu, HIP/ROCm 7.1 | 7 septembre 2026 |

Le prompt long contenait un document réseau entièrement fictif. Ce corpus de
travail n'est pas publié. Son empreinte SHA-256 était
`e01f0c1cf25b49f8cf05878609ee47916b76952ee4170295a40eae8c9cad09e9`
et llama.cpp l'a compté à 6609 tokens dans cette campagne. Vous pouvez reprendre
la méthode avec votre propre document, mais le résultat ne sera alors pas une
répétition exacte de notre essai.

Ces commandes décrivent notre méthode. Nous ne garantissons pas les mêmes
résultats sur une autre machine et nous n'avons pas validé chaque combinaison de
système, pilote et build llama.cpp.

## Lancer llama.cpp

Remplacez les chemins et l'index de carte par ceux de votre machine. Vérifiez
d'abord que le port 8080 est libre et qu'aucune autre charge n'utilise la carte.
Avec HIP, confrontez d'abord `amd-smi list` à
`llama-server --list-devices` : les index et l'ordre des cartes peuvent changer
selon la machine ou le démarrage. Une valeur dans `HIP_VISIBLE_DEVICES` expose
une carte choisie. Pour exposer toutes les cartes voulues, listez tous leurs
index préalablement vérifiés, séparés par des virgules et dans l'ordre relevé
sur votre machine.

La commande Linux ci-dessous est un **exemple mono-GPU**. Elle ne reproduit pas
T4. Notre résultat T4 emploie quatre cartes avec un ordre et une répartition des
couches propres à la workstation testée. Ce paquet ne fournit pas de commande
portable pour reproduire T4 en multi-GPU.

Sous Linux avec un build HIP :

```bash
export HIP_VISIBLE_DEVICES=0
export ROCBLAS_USE_HIPBLASLT=0
export GGML_HIP_NO_VMM=1

./llama-server \
  -m /chemin/vers/Qwen3-14B-Q4_K_M.gguf \
  -c 8192 -ngl 99 --split-mode layer --parallel 1 \
  --host 127.0.0.1 --port 8080 --no-warmup
```

Sous Windows PowerShell avec un build CUDA :

```powershell
$env:CUDA_VISIBLE_DEVICES = "0"
& .\llama-server.exe `
  -m C:\chemin\vers\Qwen3-14B-Q4_K_M.gguf `
  -c 8192 -ngl 99 --split-mode layer --parallel 1 `
  --host 127.0.0.1 --port 8080 --no-warmup
```

Le serveur doit annoncer le chargement des couches sur la ou les cartes
attendues. Un modèle qui démarre peut encore employer de la RAM partagée :
contrôlez aussi la mémoire de la carte et la mémoire système.

## Envoyer le prompt court

Le test emploie l'API brute `/completion`, sans gabarit de conversation. Depuis
la racine de ce dossier, cette commande ne demande que Python 3 :

```bash
python3 - <<'PY'
import json
import urllib.request
from pathlib import Path

payload = {
    "prompt": Path("prompts/prompt-court.txt").read_text(encoding="utf-8"),
    "n_predict": 256,
    "temperature": 0,
    "seed": 1234,
    "cache_prompt": False,
    "stream": False,
}
request = urllib.request.Request(
    "http://127.0.0.1:8080/completion",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=600) as response:
    result = json.load(response)
print(json.dumps(result.get("timings", {}), indent=2))
PY
```

Cette requête est volontairement non streamée. Elle affiche les temps du moteur
llama.cpp, mais ne mesure pas le temps avant le premier token. La colonne
correspondante du CSV vient des requêtes streamées séparées décrites plus haut.

L'appel équivalent sous Windows PowerShell est :

```powershell
$Payload = @{
  prompt = Get-Content .\prompts\prompt-court.txt -Raw
  n_predict = 256
  temperature = 0
  seed = 1234
  cache_prompt = $false
  stream = $false
} | ConvertTo-Json
$Result = Invoke-RestMethod `
  -Uri http://127.0.0.1:8080/completion `
  -Method Post -ContentType "application/json" -Body $Payload
$Result.timings
```

Faites une chauffe que vous ne comptez pas, puis trois passages identiques.
Conservez la médiane de `predicted_per_second` pour la génération et celle de
`prompt_per_second` pour la lecture de l'entrée. Ne comparez des machines
qu'avec le même fichier, le même prompt et les mêmes paramètres.

## Limites du test de quantification

Le second tableau compare
`Huihui-Qwen3.8-27B-abliterated-Q6_K.gguf` sur une R9700 de 32 Go et
`Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf` sur une RX 9070 XT de 16 Go.
Les cinq questions ont été notées à l'aveugle avec une grille fixée avant la
lecture. Les deux séries ont obtenu 20/20.

Ce résultat signifie seulement qu'aucune différence n'a été détectée sur ces
cinq questions simples et ce barème. Il ne démontre pas une qualité équivalente
en général. Les GPU étant différents, il ne mesure pas non plus l'effet isolé de
la quantification sur la vitesse. Testez vos propres tâches avant un achat.
