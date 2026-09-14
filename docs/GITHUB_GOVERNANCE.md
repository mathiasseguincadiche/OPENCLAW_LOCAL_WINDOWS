# Gouvernance GitHub

Ce document fixe les réglages GitHub attendus pour `mathiasseguincadiche/OPENCLAW_LOCAL_WINDOWS`. Les contrats présents dans le dépôt sont automatisés par CI ; les réglages administratifs GitHub doivent rester cohérents avec cette politique.

## Métadonnées du dépôt

Description cible Architecture V2 :

> Plateforme IA multi-agents local-only côté LLM pour Windows 11 : OpenClaw + Ollama, routage local hybride et qualification Intel Arc B580.

Topics cibles :

- `openclaw`
- `ollama`
- `local-ai`
- `local-llm`
- `multi-agent`
- `windows-11`
- `intel-arc`
- `powershell`
- `python`
- `devops`
- `llm`

`openrouter` ne fait plus partie des topics cibles : Architecture V2 ne supporte aucun fournisseur d'inférence LLM cloud. Si les métadonnées visibles sur GitHub diffèrent de cette cible versionnée, elles doivent être réalignées dans les réglages du dépôt sans modifier les contrats runtime pour masquer l'écart.

## Protection de `main`

Le dépôt est maintenu par un propriétaire unique. La protection doit imposer le passage par Pull Request et les contrôles automatiques sans exiger l'approbation d'un second mainteneur qui n'existe pas.

Cible pour le ruleset GitHub appliqué à `main` :

- empêcher la suppression de la branche ;
- empêcher les force-push / non-fast-forward ;
- imposer une Pull Request avant fusion ;
- ne pas imposer d'approbation humaine tant que le dépôt reste mono-mainteneur ;
- imposer la résolution des conversations avant fusion ;
- imposer une branche à jour avant fusion lorsque GitHub peut l'évaluer ;
- imposer une histoire linéaire et privilégier le squash merge ;
- ne pas autoriser de bypass permanent du propriétaire sur le parcours normal.

Checks requis après leur première exécution réussie :

```text
quality
python-3.12
python-3.13
windows-contract
Dependency Review
CodeQL / Python
```

Les règles qui exigent un deuxième approbateur ne doivent être activées qu'après ajout d'un mainteneur distinct.

### État observé le 9 septembre 2026

Le ruleset `main-protection` est actif sur la branche par défaut et applique :

- suppression interdite ;
- non-fast-forward interdit ;
- histoire linéaire ;
- Pull Request obligatoire ;
- zéro approbation imposée pour le dépôt mono-mainteneur ;
- résolution des conversations ;
- status checks en mode strict, donc branche à jour ;
- aucun acteur de bypass permanent.

Les **six checks cibles sont actuellement obligatoires** dans GitHub :

```text
quality
python-3.12
python-3.13
windows-contract
Dependency Review
CodeQL / Python
```

L'issue administrative `#8` est clôturée : il n'existe plus de dérive entre la cible versionnée et le ruleset actif sur les status checks. Toute modification future du nom d'un check doit repasser par la procédure de contrôle décrite plus bas.

## Pull Requests

Chaque changement significatif doit suivre :

```text
branche dédiée
    -> Pull Request
    -> quality : validateurs + Ruff + mypy + coverage
    -> Python 3.12 / 3.13
    -> PowerShell 7 / PSScriptAnalyzer / Pester
    -> tests de confinement Windows/Linux lorsque concernés
    -> Dependency Review
    -> CodeQL Python
    -> squash merge vers main
```

Les résultats matériels B580 et les preuves E2E avec modèles locaux ne sont jamais simulés dans GitHub Actions. Ils sont produits sur la workstation réelle puis synthétisés dans une Pull Request séparée.

## Sécurité de la supply-chain CI

- les GitHub Actions critiques sont référencées par **SHA de commit immuable** ;
- le commentaire de version (`# vX`) reste documentaire, le SHA est la référence réellement exécutée ;
- Dependabot continue à proposer les mises à jour de GitHub Actions ;
- toute mise à jour d'action doit être revue comme un changement de dépendance de build/CI.

## Sécurité

- aucun secret dans Git ;
- aucun modèle `.gguf` ou `.safetensors` dans Git ;
- aucun certificat ou keystore privé (`.key`, `.pem`, `.p12`, `.pfx`, `.jks`) ;
- CodeQL analyse le code Python ; PowerShell est contrôlé par PSScriptAnalyzer et Pester ;
- le **GitHub Dependency Graph doit être activé** pour que `actions/dependency-review-action` compare précisément les dépendances ajoutées par une Pull Request ;
- lorsque le Dependency Graph est disponible, Dependency Review bloque les nouvelles dépendances présentant une vulnérabilité de sévérité `moderate` ou supérieure ;
- tant que le Dependency Graph n'est pas activé, le workflow reste fail-closed sur les dépendances Python installées grâce à un fallback `pip-audit` et signale que le contrôle différentiel GitHub n'est pas disponible ;
- Dependabot suit `pip` et GitHub Actions ;
- les résultats runtime (`benchmarks/results`, `proofs`, `state`, `logs`, modèles) restent hors Git.

## Releases

La source de vérité de version est `VERSION`, qui doit correspondre à `project.version` dans `pyproject.toml` et à une section du `CHANGELOG.md`.

Une release utilise toujours un tag strictement égal à :

```text
v<VERSION>
```

Exemple :

```text
VERSION = 0.1.0
Tag     = v0.1.0
```

Deux chemins gouvernés sont autorisés :

1. **tag explicite** `v<VERSION>` poussé sur un commit déjà présent dans `main` ;
2. **demande de release du propriétaire** via une issue dont le titre est exactement `Release v<VERSION>`.

La seconde voie matérialise le gate humain `create_or_publish_release`. Le workflow fige le SHA courant de `main`, exécute exactement les mêmes validations Linux/Windows et ne crée le tag qu'après leur succès. Le tag est créé sur ce SHA validé, n'est jamais déplacé s'il existe déjà, puis la GitHub Release est publiée avec les artefacts, SBOM, checksums et attestations. Une issue ouverte par un autre acteur, ou avec un titre différent, ne peut pas autoriser une release.

Le workflow `Release` revalide le dépôt, la configuration, les contrats V7, le document flow, la flotte de modèles, la pédagogie transversale, le **Pre-V1 Hardening Gate**, le SemVer et le **V1 Release Readiness Gate**, puis exécute Ruff, mypy, coverage, les tests Python, PSScriptAnalyzer et Pester.

Les versions `0.x` restent des versions de développement : le manifeste de preuves matérielles V1 n'est pas requis pour leur validation SemVer.

### Verrou fail-closed pour `>=1.0.0`

Toute version majeure `>=1` doit satisfaire `config/v1/release_readiness.yaml`. Le manifeste est volontairement livré avec `approved: false` et doit rester ainsi tant que la qualification V1 réelle n'est pas terminée.

Pour autoriser une V1, le manifeste doit cibler exactement `VERSION` et contenir :

- `approved: true` ;
- verdict `APPROVED_FOR_V1` ;
- commit Git source de la qualification ;
- SHA-256 de l'identité exacte des modèles ;
- SHA-256 du résultat de qualification automatique HARD-40M ;
- SHA-256 de la preuve OpenClaw E2E ;
- SHA-256 de la preuve de stabilité du runtime Vulkan retenu, incluant redémarrage/récupération lorsque pertinent ;
- SHA-256 des golden projects ;
- SHA-256 de la preuve multimodale ;
- SHA-256 de la télémétrie réelle ;
- SHA-256 du package du projet représentatif ;
- confirmation que les limites sont documentées ;
- confirmation de l'absence de fallback **LLM cloud** nominal ;
- approbation humaine explicite, identifiée et datée en UTC.

Les preuves brutes restent hors Git conformément à la politique de confidentialité et de taille. Les SHA-256 inscrits dans le manifeste servent à **lier cryptographiquement** l'attestation versionnée aux fichiers de preuve conservés localement.

GitHub Actions ne déduit pas qu'un benchmark matériel ou qu'une revue humaine a réussi. Il vérifie seulement que la release V1 possède une attestation complète et cohérente. La responsabilité de vérifier les fichiers de preuve avant de passer `approved: true` reste humaine.

Ainsi, pousser prématurément un tag `v1.0.0` ne peut pas conduire au job `publish` tant que le manifeste est incomplet ou non approuvé.

Après validation, le workflow produit :

- wheel ;
- sdist ;
- `sbom.cdx.json` CycloneDX ;
- sommes SHA-256 ;
- attestation GitHub de provenance des artefacts ;
- attestation GitHub liant le SBOM aux artefacts.

Les permissions d'écriture et d'attestation sont limitées au job `publish`, après les jobs de validation.

## Réglages administratifs à contrôler après évolution de la CI

À chaque ajout/renommage d'un check :

1. laisser la Pull Request exécuter le nouveau check au moins une fois ;
2. vérifier son nom exact dans GitHub Actions ;
3. mettre à jour le ruleset `main` ;
4. vérifier que le merge est réellement bloqué lorsqu'un check requis échoue ;
5. documenter temporairement toute dérive entre la cible et l'état observé au lieu de l'ignorer.

## Version 1.0.0

`1.0.0` reste interdite tant que le parcours local nominal n'a pas été qualifié sur la workstation cible avec les preuves prévues dans `docs/QUALIFICATION.md`, que ces preuves n'ont pas été hashées dans `config/v1/release_readiness.yaml` et que l'approbation humaine finale n'a pas été explicitement enregistrée.
