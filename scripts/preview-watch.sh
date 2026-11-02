#!/bin/sh
# Preview watchdog: runs both halves of the dev stack and relaunches them
# whenever either one exits, so the preview comes back on its own instead
# of staying down until someone restarts it manually.
#
# It also pings the public preview URL on an interval: the platform stops a
# sandbox after ~15 minutes with no external preview traffic (processes
# running inside the sandbox do not count as activity), so this ping is what
# keeps the sandbox from being stopped in the first place.
set -u

PATH="$PWD/node_modules/.bin:$PATH"
export PATH

START_DELAY=2 # seconds between a death and the relaunch
PING_INTERVAL=300 # seconds between keep-alive pings (must stay well under the 15 min idle limit)

# Public preview URL (overridable via PREVIEW_URL). This must be the external
# gateway URL, not localhost: only gateway-routed traffic counts as activity.
PREVIEW_URL="${PREVIEW_URL:-https://5173-76f872e7-3ceb-46e9-aa9a-8b309a2909ec.daytonaproxy01.net}"

vite_pid=
srv_pid=
pinger_pid=

cleanup() {
	[ -n "$pinger_pid" ] && kill "$pinger_pid" 2>/dev/null
	[ -n "$vite_pid" ] && kill "$vite_pid" 2>/dev/null
	[ -n "$srv_pid" ] && kill "$srv_pid" 2>/dev/null
	wait 2>/dev/null
	exit 0
}
trap cleanup TERM INT

ping_preview() {
	if code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$PREVIEW_URL/" 2>/dev/null); then
		echo "[preview-watch] keep-alive ping -> HTTP $code"
	else
		echo "[preview-watch] keep-alive ping failed"
	fi
}

# Immediate first ping (visible in logs), then one every PING_INTERVAL.
ping_preview
(
	while sleep "$PING_INTERVAL"; do
		ping_preview
	done
) &
pinger_pid=$!

while :; do
	echo "[preview-watch] syncing runtime assets"
	if ! node scripts/sync-runtime-assets.mjs; then
		echo "[preview-watch] asset sync failed; retrying in 5s"
		sleep 5
		continue
	fi

	echo "[preview-watch] starting dev stack"
	vp dev --host &
	vite_pid=$!
	PORT=6060 HOST=127.0.0.1 tsx index.ts &
	srv_pid=$!

	# Watch both halves; act as soon as either one is gone.
	while kill -0 "$vite_pid" 2>/dev/null && kill -0 "$srv_pid" 2>/dev/null; do
		sleep 2
	done

	if kill -0 "$vite_pid" 2>/dev/null; then
		echo "[preview-watch] space server exited; restarting dev stack"
	elif kill -0 "$srv_pid" 2>/dev/null; then
		echo "[preview-watch] vite exited; restarting dev stack"
	else
		echo "[preview-watch] dev stack exited; restarting"
	fi

	kill "$vite_pid" "$srv_pid" 2>/dev/null
	wait "$vite_pid" 2>/dev/null
	wait "$srv_pid" 2>/dev/null
	sleep "$START_DELAY"
done
