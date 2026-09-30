# Interroger ses documents avec une IA locale

Utilisez vos propres PDF pour reproduire la démarche : une facture, un contrat,
un document scanné ou tout autre document dont vous connaissez le contenu.
Les documents montrés dans la vidéo ne sont pas distribués.

## Démarrer sous Windows ou Linux

1. Installez les versions adaptées à votre système de [LM Studio](https://lmstudio.ai/)
   et [AnythingLLM Desktop](https://docs.anythingllm.com/installation-desktop/overview).
   Sous Linux, suivez les [instructions d’installation officielles](https://docs.anythingllm.com/installation-desktop/linux).
2. Dans LM Studio, téléchargez un modèle de conversation compatible avec la mémoire
   disponible et un modèle d’embedding. La démonstration emploie GPT-OSS 20B MXFP4,
   un contexte de 8192 tokens et Nomic Embed Text v2 MoE Q6_K ; ces choix ne
   garantissent pas un chargement ni la même vitesse sur votre machine.
3. Chargez les deux modèles et démarrez le serveur local. La configuration filmée
   utilise `http://127.0.0.1:1234/v1`. Dans AnythingLLM, choisissez LM Studio pour
   [la conversation](https://docs.anythingllm.com/setup/llm-configuration/local/lmstudio)
   et [l’embedding](https://docs.anythingllm.com/setup/embedder-configuration/local/lmstudio),
   puis renseignez les identifiants réellement exposés par votre serveur.
4. Créez un nouvel espace documentaire et importez vos PDF. Vérifiez leur présence
   et la fin de l’indexation. Pour les scans, contrôlez la langue et la qualité de
   reconnaissance du texte avant d’interroger le document.
5. Préparez quelques questions dont vous pouvez vérifier la réponse dans les PDF :
   un montant, une date, une clause ou une information absente. Notez séparément
   les réponses attendues et les pages qui les justifient, sans importer ces notes
   dans l’espace documentaire.
6. Posez chaque question dans un nouveau fil. Conservez la première réponse et les
   passages cités, y compris les erreurs, puis comparez avec les documents.

Ces étapes décrivent la configuration commune des applications de bureau.
La séance filmée a été exécutée sous Windows. Les notices officielles liées ci-dessus ont été consultées le
10 septembre 2026.

Pour vérifier ce que l’API expose, sans lancer de génération :

```powershell
# Windows PowerShell
Invoke-RestMethod http://127.0.0.1:1234/v1/models
```

```bash
# Linux, serveur démarré sur la même machine
curl --fail http://127.0.0.1:1234/v1/models
```

Cette réponse vérifie l’accès local à l’API, pas l’absence de trafic Internet.
Les [API de LM Studio](https://lmstudio.ai/docs/developer) peuvent être protégées
par une authentification selon votre configuration ; gardez les identifiants privés.

## Vérifier plutôt que faire confiance

Vérifiez les pages et passages cités dans vos documents. Si deux documents se
contredisent, demandez au modèle de montrer les passages concernés. Une réponse
plausible sans source vérifiable ne suffit pas. Testez aussi une question à laquelle
vos documents ne permettent pas de répondre.

Les résultats varient avec le modèle, l’OCR, le découpage et les passages retrouvés.

## Reproduire la comparaison de vitesse

Copiez le [prompt anglais de la démonstration](examples/prompt-vitesse.txt)
dans une nouvelle conversation LM Studio. Il demande trois paragraphes sur la
mémoire du modèle, le contexte et le partage CPU/GPU, en 160 à 180 mots.

Utilisez le même modèle, la même quantification, le même contexte et les mêmes
réglages de génération pour les deux essais. Changez seulement le chargement :
toutes les couches sur le GPU, puis une partie sur le CPU. Ouvrez une nouvelle
conversation pour chaque essai et relevez le débit affiché par LM Studio après
la réponse. Les performances dépendent de votre matériel et de vos réglages.

## Observer le modèle et le réseau

Les scripts PowerShell ciblent Windows et se lancent depuis `scripts/`.
PowerShell 5.1 ou 7 convient. Pour la mesure de génération, démarrez le serveur
local de LM Studio et chargez un modèle ; renseignez exactement les paramètres
utilisés, sans reprendre ceux d’une autre machine :

```powershell
Get-Help .\mesurer-vitesse.ps1 -Full
Get-Help .\surveiller-connexions.ps1 -Full
Get-Help .\regles-pare-feu.ps1 -Full
```

- `mesurer-vitesse.ps1` vérifie le modèle chargé, conserve les passages et
  distingue le débit annoncé par le moteur d’un calcul effectué côté client.
- `surveiller-connexions.ps1` conserve une fenêtre d’observation bornée. Les
  instantanés TCP ne montrent ni tout le contenu, ni toutes les connexions brèves.
- `regles-pare-feu.ps1` inventorie les exécutables confirmés de LM Studio et
  AnythingLLM. Son appel sans option **pose des règles de blocage sortant** et
  demande les droits administrateur. `-Lister` inventorie ; `-Retirer` retire
  les règles gérées par ce script. Les autres règles restent distinctes.

La journalisation se prépare avec `-ActiverJournal` et se restaure avec
`-DesactiverJournal`. La sauvegarde d’état doit être conservée jusqu’à la
restauration réussie. Un événement réseau ou son absence ne suffit pas, seul,
à prouver le comportement d’une application.

Les sorties dans `mesures/` peuvent contenir des adresses, chemins et réglages
propres à votre poste. Gardez-les privées et préparez une copie nettoyée pour
partager un résultat. Les mesures de la vidéo sont distinctes de l’exécution de
ces outils sur votre machine.
