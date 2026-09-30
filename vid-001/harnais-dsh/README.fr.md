# DeepSeek Harness sur un serveur llama.cpp local

L'interface d'agent de la vidéo (celle qui lit les fichiers et écrit le rapport) est
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), `dsh`. Elle ne sait pas, par
défaut, parler à un serveur llama.cpp : `settings.yaml` lui déclare un fournisseur local, avec les
deux réglages de compatibilité qui manquent.

```bash
npm install -g @deepseek-ai/dsh
mkdir -p ~/.dsh && cp settings.yaml ~/.dsh/settings.yaml
export GATEWAY_API_KEY=local        # n'importe quelle valeur : llama.cpp n'en vérifie pas
dsh
```

Ce que fait la configuration :

- `baseURL` : le serveur llama.cpp (`llama-server --port 8090 --model …`) ;
- `supportsDeveloperRole: false` : llama.cpp ne connaît pas le rôle `developer` ;
- `maxTokensField: max_tokens` : le nom du champ que llama.cpp attend ;
- `models` : le nom sous lequel le serveur expose le modèle (`hy3` dans la vidéo).

Le harnais titre les sessions par un appel au modèle ; avec un modèle qui répond volontiers dans
une autre langue, le titre peut surprendre. Ça ne change rien au travail de l'agent.
