# BUILD & MIND

*Where hardware meets intelligence.*

La chaîne : [youtube.com/@build-and-mind](https://www.youtube.com/@build-and-mind)

Chaîne YouTube en français sur l'IA locale : des machines qu'on monte soi-même, des modèles qui
tournent dessus, des assistants qu'on met au travail. Derrière le masque, un ingénieur réseau et
sécurité, dix-huit ans de métier.

Ce dépôt contient de quoi refaire les démonstrations des vidéos : les scripts, les
configurations, les listes de pièces avec leurs prix, et les réponses aux questions qu'on nous pose
sous les vidéos.

## Les vidéos

| Vidéo | Dossier | Ce que vous y trouvez |
|---|---|---|
| J'ai construit un PC d'IA à plus de 10 000 € pour que tu n'aies pas à le faire | [`vid-001/`](vid-001/README.fr.md) | la démo hors ligne (un modèle de 295 milliards de paramètres sur quatre cartes AMD), l'interface d'agent branchée sur llama.cpp, le tri de photos par un modèle de vision, la liste complète des pièces |

## Comment s'en servir

Chaque dossier commence par un `README` : lisez-le avant de lancer quoi que ce soit. Les scripts
sont commentés en français et affichent ce qu'ils font. Aucun ne demande de clé ni de mot de
passe. Quand un script touche au système (des paquets installés, le réseau coupé le temps d'un
test), le README le dit en premier.

Une question, un truc qui ne marche pas chez vous ? Les commentaires sous la vidéo sont lus. Une
correction ? Les *issues* et les *pull requests* sont les bienvenues.

## Licence

Code et scripts : licence MIT (voir [`LICENSE`](LICENSE)). Le nom BUILD & MIND, le logo et les
vidéos restent la propriété de la chaîne.
