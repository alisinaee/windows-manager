#!/bin/bash
# The 18 UX states (docs/UX-AUDIT-PLAN.md). Format: name|fixture dir (WM_PROFILES_DIR=ux/fixtures/<dir>)|open query.
# Usage: scripts/ux-matrix.sh            list all states
#        scripts/ux-matrix.sh --query N  print the open query of state N
# Run the app with: WM_UX_TEST=1 WM_PROFILES_DIR=$PWD/ux/fixtures/<dir> .build/debug/WindowsManagerApp
# States that need a real condition (permission, 2-3 monitors, name conflict, errors) are marked in the notes column.
STATES='popover-empty|empty|section=popover
popover-many|many|section=popover
onboarding-before|empty|section=onboarding&permission=before|simulated, display only
onboarding-after|empty|section=onboarding&permission=after|simulated, display only
studio-sidebar-empty|empty|section=studio
studio-view-1mon|one|section=studio&profile=Work&mode=view
studio-view-multimon|many|section=studio&profile=Review&mode=view|profile with 2 displays
studio-edit-selected|many|section=studio&profile=Work&mode=edit&selectTile=0|
inspector-options|many|section=studio&profile=Work&mode=edit&inspectorTab=options|needs view hook
inspector-launch|many|section=studio&profile=Work&mode=edit&inspectorTab=launch|needs view hook
save-sheet-conflict|many|section=studio&profile=Work&mode=edit&sheet=save&saveName=Writing|name of an existing profile
capture-sheet|many|section=studio&profile=Work&mode=edit&sheet=capture
sidebar-collapsed|many|section=studio&profile=Work&mode=view&sidebar=collapsed|icon rail, toggle Cmd+Opt+S
shortcut-recorder|many|section=studio&profile=Work&mode=view&sheet=shortcut|popover: capture with UX_REGION=1
restore-preview|many|section=studio&profile=Work&mode=view&sheet=restore
studio-narrow|many|section=studio&profile=Work&mode=view&size=600x450
studio-wide|many|section=studio&profile=Work&mode=view&size=1500x900
studio-dark-edit|many|section=studio&profile=Work&mode=edit&appearance=dark
settings|many|section=settings
debug|many|section=debug'
if [ "${1:-}" = "--query" ]; then
  echo "$STATES" | awk -F'|' -v n="$2" '$1==n {print $3}'
else
  echo "$STATES" | awk -F'|' '{printf "%-24s %-6s %s %s\n", $1, $2, $3, $4}'
fi
