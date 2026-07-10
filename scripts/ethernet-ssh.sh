# SSH into the Pi on the direct ethernet cable (discovery via find-pi).
# Arguments become the remote command; with none you get an interactive
# shell. Host keys differ per card, so they are not pinned.

pi="$(find-pi)"
echo ">> connecting to admin@$pi" >&2
exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "admin@$pi" "$@"
