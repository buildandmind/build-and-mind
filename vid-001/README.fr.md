# J'ai construit un PC d'IA à plus de 10 000 € pour que tu n'aies pas à le faire

Vidéo : [lien à ajouter à la publication]

Dans la vidéo, Internet est coupé et la machine continue de lire un dossier et d'écrire son
rapport, parce que le modèle tourne sur ses quatre cartes graphiques. Ce dossier contient de quoi
refaire cette démonstration chez vous, et ce qui tourne derrière les assistants montrés à la fin
de la vidéo.

## Ce qu'il y a ici

| Dossier | Ce que c'est | Ce qu'il faut |
|---|---|---|
| [`demo-hors-ligne/`](demo-hors-ligne/README.fr.md) | installer ROCm et llama.cpp, télécharger le modèle, mesurer la vitesse, couper Internet, poser une vraie question | Ubuntu, une ou plusieurs cartes AMD, beaucoup de mémoire graphique pour ce modèle-là (un plus petit marche pareil) |
| [`harnais-dsh/`](harnais-dsh/README.fr.md) | la configuration de DeepSeek Harness pour parler à un serveur llama.cpp local | dsh, un serveur llama.cpp |
| [`tache-de-nuit/`](tache-de-nuit/README.fr.md) | le script qui trie un dossier de photos avec un modèle de vision local | llama.cpp avec un modèle de vision, chafa (facultatif) |

## La machine

Elle s'appelle Major. Quatre cartes graphiques, 112 Go de mémoire graphique cumulée : trois
cartes de 32 Go et une de 16 Go.

| Pièce | Référence | Prix d'achat, novembre 2025 |
|---|---|---:|
| Processeur | AMD Ryzen Threadripper PRO 9955WX | 1 580 € |
| Carte mère | ASUS Pro WS WRX90E-SAGE SE | 1 159 € |
| Cartes graphiques | 3 × ASRock Radeon AI PRO R9700 32 Go | 3 350 € |
| Quatrième carte | ASRock Radeon RX 9070 XT Steel Legend Dark 16 Go, montée verticale sur riser | ~720 € |
| Mémoire | G.Skill 192 Go DDR5-6000 ECC RDIMM (4 × 48 Go) | 1 521 € |
| Stockage | Samsung 990 PRO 4 To NVMe | 300 € |
| Alimentation | Seasonic PRIME PX-2200 (2200 W) | 445 € |
| Boîtier | Lian Li O11 Dynamic EVO XL, monté en mode reverse | 249 € |
| Refroidissement processeur | AORUS WATERFORCE X II 360 | 200 € |
| Ventilateurs | 10 × Lian Li UNI FAN Wireless | ~346 € |
| Câbles lumineux | Lian Li Strimer Wireless (24 broches, processeur, 3 × carte graphique) | ~270 € |
| Riser | LINKUP AVA5 PCIe 5.0, 90 cm, coudé | 138 € |
| Support vertical | Lian Li O11DEXL-1X | ~30 € |
| Écran latéral | Lian Li 8,8" Universal Screen | 90 € |
| Wi-Fi | Intel AX210NGW (kit M.2) | ~30 € |
| Divers | contrôleur ARGB, hub USB interne, adaptateurs, câble réseau | ~60 € |
| **Total** | | **~10 487 €** |

En mai 2026, les mêmes pièces étaient relevées à environ 15 850 € chez les mêmes revendeurs ; la
mémoire ECC seule était passée de 1 521 € à plus de 5 200 €. Le chiffre du titre est le coût
d'achat, arrondi, pas un prix de reconstruction.

À budget égal, AMD donne plus de mémoire graphique : les trois R9700 font 96 Go pour 3 350 €, soit
environ 35 € le Go. Le compromis, c'est la bande passante mémoire : 640 Go/s sur une R9700, contre
1 792 Go/s sur une GeForce RTX 5090 (fiches constructeur, relevé en septembre 2026). Et côté
logiciel, le chemin CUDA reste mieux balisé que ROCm.

## La démo hors ligne, en chiffres

- Modèle : Tencent Hy3, 295 milliards de paramètres dont 21 milliards actifs, fichier GGUF
  `Hy3-IQ1_M-mtp.gguf` de 91,8 Go ([AngelSlim/Hy3-GGUF](https://huggingface.co/AngelSlim/Hy3-GGUF)).
  IQ1_M est une quantification à précision mixte, pas un modèle « 1 bit ».
- Serveur : [llama.cpp](https://github.com/ggml-org/llama.cpp) compilé pour ROCm (`gfx1201`),
  modèle réparti par couches sur les quatre cartes, sans déport sur le processeur.
- Mémoire graphique occupée pendant l'enregistrement : 98,2 Go sur les quatre cartes.
- Vitesse : 18 à 30 tokens par seconde en génération sur une tâche en trois appels, contexte de
  32 768 ; médiane de 18,83 tokens par seconde au test de vitesse du 15 août 2026 (trois mesures,
  contexte de 4 096).
- Interface d'agent : [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

## Ce que vous voyez à l'écran

| Quoi | Outil |
|---|---|
| L'interface d'agent qui lit les fichiers et écrit le rapport | [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), configuration dans [`harnais-dsh/`](harnais-dsh/README.fr.md) |
| Le serveur qui fait tourner le modèle sur les quatre cartes | [llama.cpp](https://github.com/ggml-org/llama.cpp) |
| Le modèle qui répond | [Tencent Hy3 en GGUF](https://huggingface.co/AngelSlim/Hy3-GGUF) |
| Le terminal à droite : commandes en haut, mémoire des cartes en bas | [tmux](https://github.com/tmux/tmux) en deux volets, `watch -t -n 1 amd-smi monitor -v` dans celui du bas ; sur NVIDIA, `nvidia-smi` ou `nvtop` |
| L'interface de conversation des assistants de fin de vidéo | [Open WebUI](https://github.com/open-webui/open-webui), branchée sur llama.cpp |
| Le modèle qui lit le dossier client et aide sur le code | Qwen3.8 27B en GGUF, sur une carte de 32 Go |
| Le modèle de vision qui trie les photos la nuit | [Qwen3-VL 32B](https://huggingface.co/Qwen/Qwen3-VL-32B-Instruct), script dans [`tache-de-nuit/`](tache-de-nuit/README.fr.md) |
| L'assistant qui tient sur une carte de 16 Go | [Qwen3 4B](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) |
| L'aperçu des photos dans le terminal | [chafa](https://github.com/hpjansson/chafa), paquet Ubuntu |

## Questions qu'on nous pose

**Comment tu affiches ce terminal à droite ?** C'est tmux en deux volets. Le volet du haut est un
shell où les commandes sont tapées ; celui du bas fait tourner `watch -t -n 1 amd-smi monitor -v`,
la mémoire de chaque carte relue chaque seconde. Pour l'enregistrer, le terminal est servi dans
une page par ttyd, le paquet Ubuntu du même nom.

**Le modèle tient vraiment sur quatre cartes AMD ?** Oui, réparti par couches. Les chiffres
ci-dessus viennent des journaux de la session filmée. Les scripts de
[`demo-hors-ligne/`](demo-hors-ligne/README.fr.md) refont la mesure.

**Et l'assistant sur les documents, le coup de main sur le code, le tri des photos ?** Trois
sessions réelles : Open WebUI branché sur llama.cpp avec Qwen3.8 27B pour les documents ; DeepSeek
Harness avec le même modèle sur un dépôt de code ; un script de trente lignes avec Qwen3-VL 32B
pour les photos ([`tache-de-nuit/`](tache-de-nuit/README.fr.md)). L'assistant sur une seule carte
de 16 Go, c'est Qwen3 4B.
