# Diagnostic du superviseur Gateway Windows

Le Gateway OpenClaw relocalisé est possédé par la tâche Windows `OPENCLAW_LOCAL Gateway`. Le service natif OpenClaw reste diagnostic-only : un `service.runtime.status=stopped` dans `openclaw gateway status` ne signifie donc pas que le Gateway externe est arrêté.

## Commandes

Depuis la racine du dépôt :

```powershell
.\scripts\windows\27_gateway_supervisor_diagnostics.ps1 -Action status
```

Pour activer explicitement le journal Windows Task Scheduler Operational :

```powershell
.\scripts\windows\27_gateway_supervisor_diagnostics.ps1 -Action enable-log
```

L'activation du journal peut nécessiter une console élevée. Le script échoue explicitement si Windows refuse la modification.

Pour produire une preuve sous `<OPENCLAW_LOCAL_ROOT>\proofs\gateway` :

```powershell
.\scripts\windows\27_gateway_supervisor_diagnostics.ps1 -Action proof
```

La preuve corrèle :

- état de la tâche planifiée ;
- `LastTaskResult` brut, hexadécimal et classification ;
- événements récents `Microsoft-Windows-TaskScheduler/Operational` associés à la tâche ;
- listener du port `18789` et processus propriétaire ;
- readiness RPC obtenue par `openclaw gateway status --require-rpc --json` avec l'état relocalisé.

## Interprétation de `LastTaskResult`

```text
0x00000000 -> success
0x00041301 -> running
0xC000013A -> control_event_termination
autre      -> unexpected
```

`0x00041301` est le code normal d'une tâche encore en cours d'exécution.

`0xC000013A` indique que le processus a reçu une terminaison de type événement de contrôle. Ce code seul ne permet pas de conclure à un crash applicatif : il peut correspondre à un arrêt de tâche, une fermeture de session/console ou une autre interruption Windows. Utiliser la chronologie `TaskScheduler/Operational`, le listener et la readiness RPC pour établir la cause.

## Santé du Gateway externe

La santé nominale se juge sur les signaux suivants :

```text
tâche OPENCLAW_LOCAL Gateway = Running
listener 127.0.0.1:18789     = présent
processus                     = node.exe ... openclaw.mjs gateway run
rpc.ok                        = true
version                       = 2026.9.4
```

Ne pas exiger que la définition de service native OpenClaw soit `running` : elle n'est pas propriétaire du cycle de vie dans cette architecture.

## Dry-run

```powershell
.\scripts\windows\27_gateway_supervisor_diagnostics.ps1 -DryRun
```

Le DryRun ne modifie ni le journal Windows ni les preuves de la plateforme.
