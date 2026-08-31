# Site FERRA — guide de mise en ligne

Ce dossier contient **tout le site** : page d'accueil, page de téléchargement,
infos/changelog, et un vrai forum (comptes joueurs, sujets, réponses).

Rien de tout ça n'est encore en ligne — il faut faire 2 choses, une seule fois :
1. **Héberger le site** (gratuit) → GitHub Pages.
2. **Brancher le forum** à une base de données (gratuite) → Supabase.

Aucune des deux étapes ne demande de savoir coder. Compte 15-20 minutes.

---

## Étape 1 — Mettre le site en ligne (GitHub Pages)

1. Va sur [github.com](https://github.com) et crée un compte gratuit (si tu n'en as pas déjà un).
2. En haut à droite, clique **+** → **New repository**.
   - Nom : `ferra-site` (ou ce que tu veux).
   - Laisse-le **Public**.
   - Ne coche aucune case (pas de README, pas de .gitignore) — on a déjà tout.
   - Clique **Create repository**.
3. Sur la page du nouveau dépôt, GitHub te propose une adresse du style
   `https://github.com/TON-PSEUDO/ferra-site.git` — garde-la sous la main.
4. Sur ton ordinateur, ouvre un terminal **dans ce dossier `website`** et tape :
   ```bash
   git init
   git add .
   git commit -m "Premier envoi du site FERRA"
   git branch -M main
   git remote add origin https://github.com/TON-PSEUDO/ferra-site.git
   git push -u origin main
   ```
   (Remplace l'URL par la tienne, copiée à l'étape 3. Git te demandera de te
   connecter à ton compte GitHub la première fois — suis les instructions à
   l'écran.)
5. Sur GitHub, va dans l'onglet **Settings** du dépôt → section **Pages**
   (menu de gauche).
   - Source : **Deploy from a branch**.
   - Branch : **main**, dossier **/ (root)**.
   - Clique **Save**.
6. Après 1-2 minutes, ton site est en ligne à l'adresse indiquée en haut de
   cette page (du style `https://TON-PSEUDO.github.io/ferra-site/`).

**Pour mettre à jour le site plus tard** (nouvelle version du jeu, nouveau
texte...) : refais `git add .`, `git commit -m "..."`, `git push` — le site
se met à jour automatiquement en 1-2 minutes.

**Nom de domaine personnalisé (optionnel)** : si tu achètes un nom de domaine
plus tard (ex. `ferra-game.fr`), reviens dans Settings → Pages → "Custom
domain" et suis les instructions de GitHub — pas besoin de refaire le reste.

---

## Étape 2 — Brancher le forum (Supabase, gratuit)

Le forum a besoin d'un endroit où stocker les comptes/sujets/messages —
Supabase fait ça gratuitement (largement assez pour un forum de jeu).

1. Va sur [supabase.com](https://supabase.com) → **Start your project** →
   crée un compte gratuit.
2. Clique **New project**.
   - Choisis un nom (ex. `ferra-forum`).
   - Choisis un mot de passe de base de données (garde-le de côté, tu n'en
     auras normalement plus besoin après).
   - Choisis une région proche de tes joueurs (ex. Europe).
   - Clique **Create new project** (ça prend ~1-2 minutes à s'initialiser).
3. Une fois le projet prêt, dans le menu de gauche : **SQL Editor** →
   **New query**.
4. Ouvre le fichier [`supabase/schema.sql`](supabase/schema.sql) de ce
   dossier, copie **tout** son contenu, colle-le dans l'éditeur SQL de
   Supabase, puis clique **Run**. Ça crée toutes les tables du forum
   (catégories déjà pré-remplies, sujets, messages, profils joueurs).
5. Dans le menu de gauche : **Project Settings** (roue crantée, en bas) →
   **API**.
   - Copie la valeur **Project URL**.
   - Copie la valeur **anon public** (dans "Project API keys").
6. Ouvre le fichier [`assets/js/config.js`](assets/js/config.js) de ce
   dossier et remplace les 2 valeurs :
   ```js
   window.FERRA_CONFIG = {
     SUPABASE_URL: 'colle ton Project URL ici',
     SUPABASE_ANON_KEY: 'colle ta clé anon public ici',
   };
   ```
7. Renvoie le site en ligne (`git add .`, `git commit -m "Branche le forum"`,
   `git push`) — le forum fonctionne maintenant pour de vrai : les joueurs
   peuvent créer un compte, ouvrir des sujets, répondre.

### Confirmation des emails (recommandé de vérifier)
Par défaut, Supabase envoie un email de confirmation à l'inscription. Pour un
petit forum de communauté, tu peux le désactiver si tu préfères une
inscription immédiate : **Authentication** → **Providers** → **Email** →
désactive "Confirm email". Sinon, aucune action requise, ça fonctionne tel quel.

### Gérer le forum au quotidien
Tout se fait depuis le dashboard Supabase, **Table Editor** (menu de gauche) :
- Ajouter/renommer une catégorie → table `categories`.
- Supprimer un sujet ou un message inapproprié → tables `threads` / `posts`,
  clique la ligne puis Delete.
- Voir la liste des joueurs inscrits → table `profiles`.

---

## Mettre à jour le jeu téléchargeable

Le fichier téléchargé par les joueurs est [`game/FERRA.html`](game/FERRA.html).
Pour publier une nouvelle version : remplace ce fichier par la version à
jour du jeu (garde exactement ce nom), puis `git add .`, `git commit`,
`git push` comme d'habitude.

---

## Structure du dossier

```
website/
  index.html              page d'accueil
  telechargement.html     page de téléchargement du jeu
  infos.html              fonctionnalités + changelog
  game/FERRA.html         le jeu lui-même (fichier téléchargeable)
  forum/                  toutes les pages du forum
  assets/css/style.css    tous les styles du site
  assets/js/config.js     ⚠️ à remplir (voir Étape 2)
  assets/js/*.js          logique du site/forum
  supabase/schema.sql     à exécuter une fois dans Supabase (voir Étape 2)
```
