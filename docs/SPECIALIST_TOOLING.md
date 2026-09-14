# Outils métiers spécialisés

## Objectif

OPENCLAW_LOCAL enrichit les agents avec des **outils métiers bornés**, sans leur donner un shell
plus large. Le modèle choisit quand un contrôle est utile, mais le control plane décide quels
outils sont autorisés, sur quels chemins, avec quels arguments et quelles preuves.

Le contrat canonique est `config/v1/specialist_tool_policy.yaml`.

## Principe de sécurité

Le runner :

- n'utilise jamais `shell=True` ;
- refuse toute cible ou sortie hors du projet central ;
- refuse les liens, junctions et reparse points ;
- n'accepte aucun argument libre ajouté par le modèle ;
- construit la commande uniquement depuis un template versionné ;
- enregistre commande, code retour, stdout/stderr et SHA-256 de la sortie lorsqu'il y en a une ;
- échoue explicitement si le binaire requis est absent.

Les agents qui gardent `exec/process` interdits — notamment Architecte, Rédacteur et Auditeur —
ne gagnent pas de terminal. La policy exprime une autorisation **médiée** : dans la première
intégration, une tâche `ingenieur-release-forges` ou un opérateur du control plane exécute le
runner sur leurs sources validées. Aucun appel direct depuis leur session OpenClaw n'est supposé.

## Répartition

### Architecte solutions

- `mermaid_render_svg`
- `graphviz_render_svg`

L'Architecte produit la **source** du diagramme (`.mmd` ou `.dot`). Une tâche de packaging
dépendante ou un opérateur du control plane produit ensuite le SVG localement et conserve source
+ rendu + preuve.

### Ingénieur DevOps

- `terraform_fmt_check`
- `terraform_validate`
- `ansible_lint`
- `docker_compose_validate`
- `shellcheck`
- `yamllint`

L'objectif n'est pas de remplacer les commandes normales du projet, mais de disposer d'un chemin
standard de validation et de preuve.

### Ingénieur sécurité

- `gitleaks_scan`
- `trivy_fs`
- `trivy_config`
- `checkov_scan`
- `osv_scan`
- `syft_sbom`
- `grype_sbom`

La Sécurité continue de ne pas modifier les sources. Elle produit des findings et des preuves ; la
correction revient au producteur puis est rescannée.

### Release / Forges

- `publication_render`
- `mermaid_render_svg`
- `graphviz_render_svg`
- `syft_sbom`
- `grype_sbom`

La compilation multi-format et le rendu des diagrammes peuvent donc être confiés à une tâche de
packaging dépendante des sources validées du Rédacteur/Architecte. Les artefacts de release
peuvent également être accompagnés d'un SBOM et d'un contrôle de vulnérabilités.

### Rédacteur technique

- `mermaid_render_svg`
- `graphviz_render_svg`
- `markdownlint`
- `lychee_check`

La génération DOCX/PDF/HTML/Markdown est gérée par la chaîne documentaire dédiée décrite dans
`PUBLICATION_TOOLCHAIN.md`.

### Auditeur qualité

- `markdownlint`
- `lychee_check`

L'Auditeur reste non-mutant. Il contrôle aussi les manifests de publication, les hashes et, via
les outils PDF/image déjà autorisés, la qualité visuelle des rendus.

## Usage CLI

Pour les rôles qui disposent déjà d'`exec`, le runner peut être invoqué par le control plane ou
depuis un environnement opérateur :

```powershell
python .\scripts\53_run_specialist_tool.py `
  --project E:\AI\OpenClawLocal\projects\mon-projet `
  --agent ingenieur-devops `
  --tool terraform_validate `
  --target deliverables\task-terraform
```

Lister les outils d'un rôle :

```powershell
python .\scripts\53_run_specialist_tool.py `
  --project E:\AI\OpenClawLocal\projects\mon-projet `
  --agent ingenieur-securite `
  --list
```

## Preuves

Chaque exécution produit une preuve locale sous :

```text
evidence/tooling/<timestamp>-<agent>-<tool>.json
```

Un résultat positif n'est pas déduit d'une phrase du modèle : il est tiré du code retour réel et,
lorsqu'un fichier est produit, de son SHA-256.
