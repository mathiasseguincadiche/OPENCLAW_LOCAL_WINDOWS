# FinOps et services externes — Architecture V2

## Contrat actuel

Architecture V2 est **LLM local-only**. Aucun fournisseur d'inférence LLM cloud, aucun fallback LLM en ligne et aucune escalade vers OpenRouter ne sont supportés.

Le routeur `scripts/27_route_openclaw.py` conserve l'option historique `--cloud` uniquement comme surface de compatibilité fail-closed : toute tentative produit une erreur explicite. Aucune clé de fournisseur LLM cloud n'est requise par le parcours opérateur.

Les outils Web restent distincts du runtime LLM : ils peuvent interroger des sources distantes, puis les résultats sont analysés par un modèle local conformément à `config/v1/web_policy.yaml`.

## Statut du contrat `budget_policy.yaml`

`config/v1/budget_policy.yaml` et le module `clawlocal.finops` sont conservés pour la compatibilité des données/ledgers historiques V0.2 et pour éviter de rendre illisibles d'anciennes preuves. **Ils ne constituent pas une autorisation d'exécuter un LLM cloud en V2.**

Les limites historiques restent :

| Portée | Limite historique |
|---|---:|
| journée | 1,00 EUR |
| mois | 5,00 EUR |
| projet / mois | 2,00 EUR |

Le ledger historique reste, lorsqu'il existe :

```text
<OPENCLAW_LOCAL_ROOT>\state\finops\cloud-costs.jsonl
```

Il reste hors Git et append-only. Les anciennes entrées `reservation`, `settlement`, `release` et `cost` peuvent être relues pour audit, mais le routage V2 ne crée pas d'appel LLM cloud à partir de ces données.

## Services externes non-LLM

Une future intégration payante non-LLM (recherche Web, forge, stockage ou autre API) devra disposer d'un contrat dédié avant activation réelle. Elle ne pourra pas réutiliser implicitement l'ancien contrat OpenRouter pour contourner l'invariant local-only.

Exigences minimales :

- service explicitement identifié ;
- données autorisées selon la classification du projet ;
- coût attribuable et journalisé lorsqu'il existe ;
- secrets hors Git et hors preuves publiables ;
- approbation humaine lorsque le contrat de projet l'exige ;
- aucun transfert de prompt/document vers un fournisseur LLM cloud ;
- raisonnement LLM toujours local.

## Invariant opérateur

```text
LLM cloud                  : NON SUPPORTÉ
Fallback LLM en ligne      : INTERDIT
Outils Web distants        : AUTORISÉS SOUS POLITIQUE
Raisonnement après Web     : LOCAL
budget_policy.yaml         : COMPATIBILITÉ HISTORIQUE, PAS UNE ROUTE LLM
```

Toute documentation ou configuration active qui demanderait une clé OpenRouter, proposerait `--cloud` comme voie d'exécution ou annoncerait une escalade LLM cloud doit être considérée comme une régression Architecture V2.
