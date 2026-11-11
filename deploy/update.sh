#!/usr/bin/env bash
# Update factorio-ha on the Factorio server, in one command (run on the server):
#
#   deploy/update.sh            relay + mod; asks before restarting the game
#   deploy/update.sh relay      only the relay (the game keeps running)
#   deploy/update.sh mod        only the mod (restarts the game if there is a new version)
#   deploy/update.sh -y ...     no questions
#
# Relay: git pull + `docker compose up -d --build factorio-ha-relay`. Unchanged code
# hits the Docker build cache and the container is left as it is.
# Mod: compares the installed zip with the latest release for Factorio 2.1 on the mod
# portal and installs a newer one with factorio-add-mods.sh (stops/starts the game).
#
# Optional settings in /root/.factorio-ha-update.env (chmod 600) or the environment:
#   COMPOSE_FILE     default /opt/factorio/docker-compose.yml
#   MODS_DIR         default /opt/factorio/data/mods
#   ADD_MODS_SCRIPT  default /root/factorio-add-mods.sh
#   FUSER, FTOKEN    mod portal username/token, so factorio-add-mods.sh does not ask
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SETTINGS_FILE=${SETTINGS_FILE:-/root/.factorio-ha-update.env}
# shellcheck disable=SC1090
[ -f "$SETTINGS_FILE" ] && . "$SETTINGS_FILE"
COMPOSE_FILE=${COMPOSE_FILE:-/opt/factorio/docker-compose.yml}
MODS_DIR=${MODS_DIR:-/opt/factorio/data/mods}
ADD_MODS_SCRIPT=${ADD_MODS_SCRIPT:-/root/factorio-add-mods.sh}
FACTORIO_VERSION=${FACTORIO_VERSION:-2.1}
MOD=factorio-ha

YES=0
WHAT=all
for arg in "$@"; do
  case $arg in
    -y|--yes) YES=1 ;;
    relay|mod|all) WHAT=$arg ;;
    *) echo "usage: $0 [-y] [relay|mod|all]"; exit 2 ;;
  esac
done

confirm() {
  [ "$YES" = 1 ] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer =~ ^[Yy] ]]
}

update_relay() {
  echo "== relay"
  git -C "$REPO" pull --ff-only --quiet
  echo "code: $(git -C "$REPO" log -1 --format='%h %s (%cr)')"
  docker compose -f "$COMPOSE_FILE" up -d --build factorio-ha-relay
  sleep 3
  docker logs factorio-ha-relay --tail 5
}

installed_mod_version() {
  local f v versions=""
  for f in "$MODS_DIR/${MOD}_"*.zip; do
    [ -e "$f" ] || continue
    v=${f##*/"${MOD}"_}
    versions+="${v%.zip}"$'\n'
  done
  printf '%s' "$versions" | sort -V | tail -1
}

latest_mod_version() {
  curl -fsS "https://mods.factorio.com/api/mods/$MOD" \
    | jq -r --arg fv "$FACTORIO_VERSION" '[.releases[] | select(.info_json.factorio_version == $fv)] | last | .version // empty'
}

update_mod() {
  echo "== mod"
  local installed latest
  installed=$(installed_mod_version)
  latest=$(latest_mod_version)
  echo "installed: ${installed:-none}, mod portal: ${latest:-?}"
  if [ -z "$latest" ]; then
    echo "!! Could not read the mod portal; skipping the mod"
    return 0
  fi
  local newest
  newest=$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)
  if [ "$installed" = "$latest" ] || [ "$newest" != "$latest" ]; then
    echo "mod is up to date"
    return 0
  fi
  if ! confirm "Install $MOD $latest? This restarts the game (players get disconnected)."; then
    echo "mod: skipped"
    return 0
  fi
  FUSER=${FUSER:-} FTOKEN=${FTOKEN:-} bash "$ADD_MODS_SCRIPT" "$MOD"
}

case $WHAT in
  relay) update_relay ;;
  mod) update_mod ;;
  all) update_relay; update_mod ;;
esac
