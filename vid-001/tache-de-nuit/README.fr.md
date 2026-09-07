# La tâche de nuit : trier des photos avec un modèle de vision local

`trier-photos.sh` prend un dossier de photos, envoie chaque image à un modèle de vision qui tourne
sur la machine, et renomme le fichier d'après ce que le modèle voit. Un journal CSV garde le couple
ancien nom / nouveau nom / description. Rien ne sort de la machine : l'adresse appelée est la boucle
locale.

```bash
./trier-photos.sh /chemin/vers/les/photos
```

Il faut :

- un serveur llama.cpp qui sert un modèle de vision, en API compatible OpenAI. Dans la vidéo :
  [Qwen3-VL 32B](https://huggingface.co/Qwen/Qwen3-VL-32B-Instruct) en GGUF, sur une carte de 32 Go.
  Un modèle de vision plus petit marche sur une carte de 16 Go ;
- `python3` (livré avec Ubuntu) ;
- `chafa`, facultatif (`sudo apt install chafa`) : il dessine l'aperçu de chaque photo dans le
  terminal, ce qui montre que le modèle reçoit bien une image. Sans lui, le script marche pareil.

Variables : `PASSERELLE` (adresse du serveur, défaut `http://127.0.0.1:20000/v1/chat/completions`),
`MODELE` (nom du modèle côté serveur, défaut `qwen3-vl`), `JOURNAL` (chemin du CSV).
