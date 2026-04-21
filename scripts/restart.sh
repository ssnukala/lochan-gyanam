for app in /home/apps/gyanam/apps/*/; do
  [ -f "$app/compose.dev.yml" ] && (cd "$app" && docker compose -f compose.dev.yml up -d --force-recreate frontend 2>/dev/null) &
done
wait
