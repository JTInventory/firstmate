# Routage des PR JT (app vs pipeline)

Reference durable pour tout agent Firstmate/Codex/Claude qui prepare une PR sur le travail JT.
Definition canonique : le README de `JTInventory/jt-war-room` fait foi ; ce fichier ne fait que la pointer et resumer le routage.

## Deux flux, deux repos

- **Code app / UI / composants / lib runtime / design / config Hosting** (`firebase.json`, `prepare-firebase-hosting.mjs`) : PR sur `JTInventory/jt-war-room` ; merge sur `main` => deploy Firebase automatique (`deploy.yml`). Deploy : OUI.
- **Regles Storage** (`storage.rules`) : PR sur `JTInventory/jt-war-room` ; deploy manuel avec `firebase deploy --only storage --project jt-war-room`. Deploy : MANUEL.
- **Pipeline / donnees / CI et workflows du pipeline OpenClaw** (generateurs, timers, serve-follow-main, scripts OpenClaw) : PR sur `JTInventory/Openclaw-Backup`. Aucun deploy ; la branche `data` + Storage suivent le refresh. Deploy : NON.

## Garde

Openclaw-Backup est gele pour l'app : sa CI bloque `app/`, `components/`, `lib/` (runtime), `design-system/` et `docs/design/` (garde `app-code-freeze`) et pointe vers jt-war-room.
Une PR qui touche ces chemins doit etre rouverte sur jt-war-room.

## Verification d'un deploy

- Run : `gh run list --workflow=deploy.yml --repo JTInventory/jt-war-room`
- Commit servi : `https://jt-war-room.web.app/serve-build-info.json`
- Check local : `bash /root/.openclaw-serve/check-firebase-deploy-state.sh`
