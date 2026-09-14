# Chaîne de publication documentaire

## Objectif

La documentation OPENCLAW_LOCAL doit être aussi vérifiable et reproductible que le code. Le
Rédacteur produit une **source canonique Quarto (`.qmd`)** ; le control plane la rend localement
dans quatre formats :

```text
QMD canonique
   ├── GitHub Markdown
   ├── HTML autonome
   ├── DOCX
   └── PDF via Typst
```

Le contrat est `config/v1/documentation_publication_policy.yaml`.

## Toolchain nominale

Versions de référence verrouillées dans `config/v1/runtime_versions.json` :

- Quarto `1.10.18` ;
- Typst `0.15.0` ;
- `@mermaid-js/mermaid-cli` `11.17.0` ;
- Graphviz `16.1.0`.

Quarto reste l'orchestrateur documentaire. Le PDF nominal utilise le format Typst. Mermaid et
Graphviz produisent des diagrammes locaux, versionnables, préférentiellement en SVG.

## Source unique

Le Rédacteur ne rédige pas quatre documents indépendants. Il produit une source `.qmd`, idéalement
à partir de `templates/publication/REPORT_TEMPLATE.qmd`.

Le contenu attendu suit, lorsque pertinent, la progression pédagogique :

1. **Comprendre** ;
2. **Utiliser** ;
3. **Approfondir** ;
4. **Diagnostiquer**.

Un bon dossier de projet contient aussi une vue d'ensemble, une carte des outils, l'architecture,
les preuves, le troubleshooting, le glossaire et l'appropriation pédagogique.

## Rendu

Exécution manuelle contrôlée :

```powershell
python .\scripts\52_render_project_publication.py `
  --project E:\AI\OpenClawLocal\projects\mon-projet `
  --source deliverables\task-doc\PROJECT_GUIDE.qmd
```

Le rendu crée un sous-dossier `rendered/` contenant :

```text
PROJECT_GUIDE.md
PROJECT_GUIDE.html
PROJECT_GUIDE.docx
PROJECT_GUIDE.pdf
publication_manifest.json
```

## Manifest

Le manifest enregistre :

- chemin et SHA-256 de la source canonique ;
- outils et versions observées ;
- commandes de rendu ;
- code retour ;
- chemin, taille et SHA-256 de chaque rendu ;
- résultat des contrôles structurels.

La validation recalcule tous les hashes. Toute divergence bloque la promotion du document.

## Contrôles structurels

Avant qu'un rendu soit considéré comme valide :

- Markdown : non vide et structuré par titres ;
- HTML : document complet avec `<html>` et `<title>` ;
- DOCX : conteneur Office valide avec `word/document.xml` et `word/styles.xml` ;
- PDF : signature PDF valide ;
- tous les formats : SHA-256 enregistré.

Ces contrôles ne remplacent pas la **revue visuelle**. L'Auditeur doit encore inspecter le PDF et
le DOCX lorsque la présentation est un livrable important : lisibilité des tableaux, taille des
diagrammes, coupures de code, hiérarchie des titres et cohérence générale.

## Diagrammes

Les diagrammes restent diagram-as-code :

```text
architecture.mmd -> architecture.svg
network.dot      -> network.svg
```

Le fichier source et le SVG sont tous deux conservés. Un diagramme rendu n'est jamais la seule
source de vérité.

## Intégration dans l'orchestration

Dans cette première intégration, le rendu n'est **pas** un shell donné au Rédacteur ou à
l'Architecte. Le plan de projet doit créer une tâche de packaging `ingenieur-release-forges` qui
dépend des sources documentaires et diagrammes validés. Cette tâche appelle le runner borné pour :

- rendre les `.mmd`/`.dot` en SVG ;
- recopier la source `.qmd` validée dans le périmètre de sortie de la tâche Release, puis la compiler en Markdown, HTML, DOCX et PDF ;
- ne jamais écrire un rendu dans `intake/`, `sources/` ou `context/exchange/` ;
- produire les manifests et hashes ;
- échouer explicitement si un renderer requis manque ou retourne une erreur.

Le helper `postprocess_task_outputs()` existe côté control plane pour une future automatisation
post-collecte, mais aucun automatisme implicite n'est revendiqué tant qu'il n'est pas câblé dans
l'orchestrateur. La séparation auteur -> compilateur -> auditeur reste donc explicite et traçable.

L'objectif final est qu'un projet puisse être compris dans Git, présenté à un jury en PDF,
retravaillé dans Word et consulté en HTML sans divergence de contenu.
