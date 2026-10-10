#!/bin/bash
# Drives a running HyperBrowser launched with --automation.
#   scripts/ui.sh snapshot [/path/out.png] | tree | state | type "text" | key cmd+l | click X Y
#   scripts/ui.sh action focusAddressBar | eval "document.title"
DIR="${HB_AUTOMATION_DIR:-$HOME/Library/Application Support/HyperBrowser/Automation}"
ID=$$-$RANDOM
case "$1" in
  snapshot) JSON=$(python3 -c 'import json,sys;d={"id":sys.argv[1],"cmd":"snapshot","path":sys.argv[2] or "/tmp/hb-snapshot.png"}
if len(sys.argv)>3 and sys.argv[3]: d["window"]=sys.argv[3]
print(json.dumps(d))' "$ID" "$2" "$3") ;;
  type)     JSON=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cmd":"type","text":sys.argv[2]}))' "$ID" "$2") ;;
  key)      JSON="{\"id\":\"$ID\",\"cmd\":\"key\",\"key\":\"$2\"}" ;;
  click)    JSON="{\"id\":\"$ID\",\"cmd\":\"click\",\"x\":$2,\"y\":$3}" ;;
  action)   JSON="{\"id\":\"$ID\",\"cmd\":\"action\",\"name\":\"$2\"}" ;;
  eval)     JSON=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cmd":"eval","js":sys.argv[2]}))' "$ID" "$2") ;;
  load)     JSON=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cmd":"load","url":sys.argv[2]}))' "$ID" "$2") ;;
  sheet)    JSON=$(python3 -c 'import json,sys;d={"id":sys.argv[1],"cmd":"sheet"}
if len(sys.argv)>2: d["press"]=sys.argv[2]
print(json.dumps(d))' "$ID" "$2") ;;
  drag)     JSON="{\"id\":\"$ID\",\"cmd\":\"drag\",\"x\":$2,\"y\":$3,\"toX\":$4,\"toY\":$5}" ;;
  install)  JSON=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cmd":"install","path":sys.argv[2]}))' "$ID" "$2") ;;
  extop)    JSON="{\"id\":\"$ID\",\"cmd\":\"extop\",\"op\":\"$2\"}" ;;
  tab)      JSON="{\"id\":\"$ID\",\"cmd\":\"tab\",\"op\":\"$2\",\"index\":$3}" ;;
  ghost)    JSON=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cmd":"ghost","live":sys.argv[2],"ghost":sys.argv[3]}))' "$ID" "$2" "$3") ;;
  tree|state|front|webkit|gc|extensions) JSON="{\"id\":\"$ID\",\"cmd\":\"$1\"}" ;;
  *) echo "usage: see header"; exit 2 ;;
esac
rm -f "$DIR/result.json"
echo "$JSON" > "$DIR/command.json.tmp" && mv "$DIR/command.json.tmp" "$DIR/command.json"
for _ in $(seq 1 100); do
  if [ -f "$DIR/result.json" ] && grep -q "\"$ID\"" "$DIR/result.json"; then
    python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));print(r["output"]);sys.exit(0 if r["ok"] else 1)' "$DIR/result.json"; exit $?
  fi
  sleep 0.1
done
echo "timeout: is the app running with --automation?"; exit 1
