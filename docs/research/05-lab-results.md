# Spaces Lab report

| Test | Started (UTC) | Duration | macOS | Result | Steps |
|---|---|---|---|---|---|
| restore | 2026-10-26T14:41:43Z | 0.0s | Version 27.0.1 (Build 26A434) | n/a | 3 |
| restore | 2026-10-26T14:41:48Z | 20.0s | Version 27.0.1 (Build 26A434) | FAIL | 8 |
| restore | 2026-10-26T14:44:46Z | 1.0s | Version 27.0.1 (Build 26A434) | FAIL | 5 |
| restore | 2026-10-26T14:48:22Z | 1.0s | Version 27.0.1 (Build 26A434) | FAIL | 5 |
| restore | 2026-10-26T14:48:55Z | 0.0s | Version 27.0.1 (Build 26A434) | FAIL | 5 |
| restore | 2026-10-26T14:51:32Z | 1.0s | Version 27.0.1 (Build 26A434) | PASS | 5 |
| restore | 2026-10-26T14:51:59Z | 3.0s | Version 27.0.1 (Build 26A434) | PASS | 9 |
| move-probe | 2026-10-29T13:22:19Z | 0.0s | Version 27.0.1 (Build 26A434) | n/a | 0 |
| switch-probe | 2026-10-29T13:22:19Z | 0.0s | Version 27.0.1 (Build 26A434) | n/a | 2 |
| order-file-apply | 2026-10-29T13:22:30Z | 10.0s | Version 27.0.1 (Build 26A434) | FAIL | 7 |
| order-file-restore | 2026-10-29T13:22:47Z | 1.0s | Version 27.0.1 (Build 26A434) | PASS | 4 |

## restore

File: `restore-20261026-181143.json`  
Result: n/a

Observations:

- `mode`: dry-run
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : true,
  "elapsed" : 0.2675970833370229,
  "finishedAt" : "2026-10-26T14:41:43Z",
  "launched" : [

  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:41:43Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 0,
      "index" : 1,
      "kind" : "launch",
      "phase" : "launch",
      "status" : {
        "reason" : "dry run",
        "status" : "skipped"
      }
    }
  ],
  "summary" : "Dry run: 0 windows to change, 1 app to launch, 1 not found",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 0,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 1,
    "steps" : 1,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 1,
    "windowsPartial" : 0,
    "windowsPlaced" : 0,
    "windowsPlanned" : 0
  },
  "unmatched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "reason" : "the app is not running; it will be launched",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [
        "the app is not running; it will be launched"
      ],
      "outcome" : "notFound",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ]
}
- `steps`: 1 (0 done, 1 skipped, 0 failed)
- `summary`: Dry run: 0 windows to change, 1 app to launch, 1 not found
- `windows`: 0 placed, 0 partial, 0 failed, 1 not found

## restore

File: `restore-20261026-181148.json`  
Result: FAIL

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 20.29129545832984,
  "finishedAt" : "2026-10-26T14:42:08Z",
  "launched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "elapsed" : 20.00733183333068,
      "launched" : false,
      "result" : "timed out",
      "windowCount" : 0
    }
  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:41:48Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 20.00733183333068,
      "index" : 1,
      "kind" : "launch",
      "phase" : "launch",
      "status" : {
        "reason" : "timed out waiting for 1 window",
        "status" : "failed"
      }
    },
    {
      "app" : "TextEdit",
      "description" : "set frame 600x400 at 300,200 (now 603x505 at 309,103): TextEdit \"Untitled\" (window 5500)",
      "elapsed" : 0.03232949999801349,
      "index" : 2,
      "kind" : "setFrame",
      "phase" : "setFrame",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "status" : {
        "reason" : "window not reachable by Accessibility",
        "status" : "failed"
      },
      "windowID" : 5500
    }
  ],
  "summary" : "1 failed",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 0,
    "driftCorrections" : 0,
    "failed" : 2,
    "skipped" : 0,
    "steps" : 2,
    "windowsFailed" : 1,
    "windowsNotDone" : 0,
    "windowsNotFound" : 0,
    "windowsPartial" : 0,
    "windowsPlaced" : 0,
    "windowsPlanned" : 0
  },
  "unmatched" : [

  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [
        "setFrame: window not reachable by Accessibility"
      ],
      "outcome" : "failed",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled",
      "windowID" : 5500
    }
  ]
}
- `steps`: 2 (0 done, 0 skipped, 2 failed)
- `summary`: 1 failed
- `windows`: 0 placed, 0 partial, 1 failed, 0 not found

## restore

File: `restore-20261026-181446.json`  
Result: FAIL

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 0.25067033333471045,
  "finishedAt" : "2026-10-26T14:44:47Z",
  "launched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "elapsed" : 0.01338791666785255,
      "launched" : false,
      "result" : "already running",
      "windowCount" : 1
    }
  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:44:46Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 0.01338791666785255,
      "index" : 1,
      "kind" : "launch",
      "phase" : "launch",
      "status" : {
        "reason" : "already running",
        "status" : "skipped"
      }
    }
  ],
  "summary" : "1 not found",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 0,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 1,
    "steps" : 1,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 1,
    "windowsPartial" : 0,
    "windowsPlaced" : 0,
    "windowsPlanned" : 0
  },
  "unmatched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "reason" : "the app has fewer windows open than the profile",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [
        "the app has fewer windows open than the profile"
      ],
      "outcome" : "notFound",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ]
}
- `steps`: 1 (0 done, 1 skipped, 0 failed)
- `summary`: 1 not found
- `windows`: 0 placed, 0 partial, 0 failed, 1 not found

## restore

File: `restore-20261026-181822.json`  
Result: FAIL

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 0.27404204166668933,
  "finishedAt" : "2026-10-26T14:48:23Z",
  "launched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "elapsed" : 0.017534416670969222,
      "launched" : false,
      "result" : "already running",
      "windowCount" : 1
    }
  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:48:22Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 0.017534416670969222,
      "index" : 1,
      "kind" : "launch",
      "phase" : "launch",
      "status" : {
        "reason" : "already running",
        "status" : "skipped"
      }
    }
  ],
  "summary" : "1 not found",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 0,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 1,
    "steps" : 1,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 1,
    "windowsPartial" : 0,
    "windowsPlaced" : 0,
    "windowsPlanned" : 0
  },
  "unmatched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "reason" : "the app has fewer windows open than the profile",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [
        "the app has fewer windows open than the profile"
      ],
      "outcome" : "notFound",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ]
}
- `steps`: 1 (0 done, 1 skipped, 0 failed)
- `summary`: 1 not found
- `windows`: 0 placed, 0 partial, 0 failed, 1 not found

## restore

File: `restore-20261026-181855.json`  
Result: FAIL

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 0.25951245833857683,
  "finishedAt" : "2026-10-26T14:48:55Z",
  "launched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "elapsed" : 0.02089374999923166,
      "launched" : false,
      "result" : "already running",
      "windowCount" : 1
    }
  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:48:55Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 0.02089374999923166,
      "index" : 1,
      "kind" : "launch",
      "phase" : "launch",
      "status" : {
        "reason" : "already running",
        "status" : "skipped"
      }
    }
  ],
  "summary" : "1 not found",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 0,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 1,
    "steps" : 1,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 1,
    "windowsPartial" : 0,
    "windowsPlaced" : 0,
    "windowsPlanned" : 0
  },
  "unmatched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "reason" : "the app has fewer windows open than the profile",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [
        "the app has fewer windows open than the profile"
      ],
      "outcome" : "notFound",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled"
    }
  ]
}
- `steps`: 1 (0 done, 1 skipped, 0 failed)
- `summary`: 1 not found
- `windows`: 0 placed, 0 partial, 0 failed, 1 not found

## restore

File: `restore-20261026-182132.json`  
Result: PASS

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 1.5244362916637328,
  "finishedAt" : "2026-10-26T14:51:33Z",
  "launched" : [

  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:51:32Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "set frame 600x400 at 300,200 (now 603x505 at 309,103): TextEdit \"Untitled\" (window 5500)",
      "elapsed" : 0.12044879166933242,
      "index" : 1,
      "kind" : "setFrame",
      "phase" : "setFrame",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "status" : {
        "status" : "done"
      },
      "windowID" : 5500
    }
  ],
  "summary" : "1 window placed",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 0,
    "appsNeedingConfirmation" : 0,
    "done" : 1,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 0,
    "steps" : 1,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 0,
    "windowsPartial" : 0,
    "windowsPlaced" : 1,
    "windowsPlanned" : 0
  },
  "unmatched" : [

  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [

      ],
      "outcome" : "placed",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled",
      "windowID" : 5500
    }
  ]
}
- `steps`: 1 (1 done, 0 skipped, 0 failed)
- `summary`: 1 window placed
- `windows`: 1 placed, 0 partial, 0 failed, 0 not found

## restore

File: `restore-20261026-182159.json`  
Result: PASS

Observations:

- `mode`: execute
- `profile`: Captured workspace (/private/tmp/claude-501/-Users-ali-Works-windows-manager/0353b23e-72f9-488c-b806-d4530f5ff8e6/scratchpad/test.json)
- `report`: {
  "ambiguous" : [

  ],
  "cancelled" : false,
  "dryRun" : false,
  "elapsed" : 2.8191222916648258,
  "finishedAt" : "2026-10-26T14:52:02Z",
  "launched" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "elapsed" : 1.3888306250009919,
      "launched" : true,
      "result" : "launched",
      "windowCount" : 1
    }
  ],
  "needsConfirmation" : [

  ],
  "profileID" : "D8B91E8C-B0FB-4D8A-8899-4699AEBDB65A",
  "profileName" : "Captured workspace",
  "startedAt" : "2026-10-26T14:51:59Z",
  "steps" : [
    {
      "app" : "TextEdit",
      "description" : "launch TextEdit (1 window)",
      "elapsed" : 1.3888306250009919,
      "index" : 1,
      "kind" : "launch",
      "note" : "1 of 1 window ready",
      "phase" : "launch",
      "status" : {
        "status" : "done"
      }
    },
    {
      "app" : "TextEdit",
      "description" : "set frame 600x400 at 300,200 (now 603x505 at 309,103): TextEdit \"Untitled\" (window 5608)",
      "elapsed" : 0.03516341666545486,
      "index" : 2,
      "kind" : "setFrame",
      "phase" : "setFrame",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "status" : {
        "status" : "done"
      },
      "windowID" : 5608
    }
  ],
  "summary" : "1 window placed, 1 launched",
  "totals" : {
    "appsHidden" : 0,
    "appsLaunched" : 1,
    "appsNeedingConfirmation" : 0,
    "done" : 2,
    "driftCorrections" : 0,
    "failed" : 0,
    "skipped" : 0,
    "steps" : 2,
    "windowsFailed" : 0,
    "windowsNotDone" : 0,
    "windowsNotFound" : 0,
    "windowsPartial" : 0,
    "windowsPlaced" : 1,
    "windowsPlanned" : 0
  },
  "unmatched" : [

  ],
  "warnings" : [

  ],
  "windows" : [
    {
      "app" : {
        "bundleID" : "com.apple.TextEdit",
        "name" : "TextEdit",
        "path" : "\/System\/Applications\/TextEdit.app"
      },
      "notes" : [

      ],
      "outcome" : "placed",
      "snapshotID" : "A58C789B-6EBD-4462-AE6A-97CC64D94D51",
      "title" : "Untitled",
      "windowID" : 5608
    }
  ]
}
- `steps`: 2 (2 done, 0 skipped, 0 failed)
- `summary`: 1 window placed, 1 launched
- `windows`: 1 placed, 0 partial, 0 failed, 0 not found

## move-probe

File: `move-probe-20261029-165219.json`  
Result: n/a

Observations:

- `classes-matching`: SLSAsynchronousBridgedWindowManagementOperation, SLSBridgedAddWindowsToSpacesOperation, SLSBridgedCopyAssociatedWindowsOperation, SLSBridgedCopyBestManagedDisplayForPointOperation, SLSBridgedCopyBestManagedDisplayForRectOperation, SLSBridgedCopyManagedDisplayForSpaceOperation, SLSBridgedCopyManagedDisplayForWindowOperation, SLSBridgedCopyManagedDisplaySpacesOperation, SLSBridgedCopyManagedDisplaysOperation, SLSBridgedCopySpacesForWindowsOperation, SLSBridgedCopySpacesOperation, SLSBridgedCopyWindowsWithOptionsAndTagsAndSpaceOptionsOperation, SLSBridgedCopyWindowsWithOptionsAndTagsOperation, SLSBridgedGetSpaceManagementModeOperation, SLSBridgedGetSpaceNeedsSafeApertureOperation, SLSBridgedGetSpacePermittedResizeDirectionsOperation, SLSBridgedGetTileSpaceDividerDirectionsOperation, SLSBridgedHideSpacesOperation, SLSBridgedManagedDisplayCurrentSpaceAllowsWindowOperation, SLSBridgedManagedDisplayGetCurrentSpaceOperation, SLSBridgedManagedDisplayIsAnimatingOperation, SLSBridgedManagedDisplaySetCurrentSpaceOperation, SLSBridgedManagedDisplaySetIsAnimatingOperation, SLSBridgedManagedDisplaySetRoleWindowOperation, SLSBridgedManagedDisplaysCopyRoleWindowsOperation, SLSBridgedMoveManagedSpaceToDisplayIndexOperation, SLSBridgedMoveWindowsToManagedSpaceOperation, SLSBridgedProcessAssignToAllSpacesOperation, SLSBridgedProcessAssignToSpaceOperation, SLSBridgedRemoveWindowsFromSpacesOperation, SLSBridgedResetWindowsOperation, SLSBridgedSetSpaceManagementModeOperation, SLSBridgedShowSpacesOperation, SLSBridgedSpaceAddOwnerOperation, SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation, SLSBridgedSpaceCanCreateTileOperation, SLSBridgedSpaceClientDrivenMoveSpacersToPointFencedOperation, SLSBridgedSpaceClientDrivenMoveSpacersToPointOperation, SLSBridgedSpaceCopyManagedShapeOperation, SLSBridgedSpaceCopyNameOperation, SLSBridgedSpaceCopyOwnersOperation, SLSBridgedSpaceCopyShapeOperation, SLSBridgedSpaceCopyTileSpacesOperation, SLSBridgedSpaceCopyValuesOperation, SLSBridgedSpaceCreateOperation, SLSBridgedSpaceCreateTileOperation, SLSBridgedSpaceDestroyOperation, SLSBridgedSpaceFinishedResizeForRectOperation, SLSBridgedSpaceGetAbsoluteLevelOperation, SLSBridgedSpaceGetAlphaOperation, SLSBridgedSpaceGetInterTileSpacingOperation, SLSBridgedSpaceGetRectOperation, SLSBridgedSpaceGetSizeForProposedTileOperation, SLSBridgedSpaceGetSpacersAtPointOperation, SLSBridgedSpaceGetTransformOperation, SLSBridgedSpaceGetTypeOperation, SLSBridgedSpacePreferCurrentDisplayOperation, SLSBridgedSpaceRemoveOwnerOperation, SLSBridgedSpaceRemoveValuesForKeysOperation, SLSBridgedSpaceResetMenuBarOperation, SLSBridgedSpaceSetAbsoluteLevelOperation, SLSBridgedSpaceSetAlphaOperation, SLSBridgedSpaceSetEdgeReservationOperation, SLSBridgedSpaceSetFrontPSNOperation, SLSBridgedSpaceSetInterTileSpacingOperation, SLSBridgedSpaceSetNameOperation, SLSBridgedSpaceSetOrderingWeightOperation, SLSBridgedSpaceSetOwnersOperation, SLSBridgedSpaceSetShapeOperation, SLSBridgedSpaceSetTransformOperation, SLSBridgedSpaceSetValuesOperation, SLSBridgedSpaceTileMoveToSpaceAtIndexOperation, SLSBridgedSpaceWithNameOperation, SLSBridgedTileSpaceMoveSpacersForSizeFencedOperation, SLSBridgedTileSpaceMoveSpacersForSizeOperation, SLSBridgedTileSpaceReplaceWithSnapshotWindowOperation, SLSBridgedTileSpaceSetDividerWindowOperation, SLSBridgedTileSpaceTakeOwnershipOperation, SLSBridgedWillSwitchSpacesOperation, SLSBridgedWindowGetTileRectOperation, SLSBridgedWindowManagementOperationAffineTransformWithOptionsResult, SLSBridgedWindowManagementOperationBoolResult, SLSBridgedWindowManagementOperationFloatResult, SLSBridgedWindowManagementOperationInt32Result, SLSBridgedWindowManagementOperationNumbersResult, SLSBridgedWindowManagementOperationProcessIdentifierResult, SLSBridgedWindowManagementOperationPropertyListArrayResult, SLSBridgedWindowManagementOperationPropertyListDictionaryResult, SLSBridgedWindowManagementOperationRectResult, SLSBridgedWindowManagementOperationRegionResult, SLSBridgedWindowManagementOperationResult, SLSBridgedWindowManagementOperationSizeResult, SLSBridgedWindowManagementOperationSpaceIDResult, SLSBridgedWindowManagementOperationSpaceManagementModeResult, SLSBridgedWindowManagementOperationSpaceResizeDirectionsResult, SLSBridgedWindowManagementOperationSpacerIndexesResult, SLSBridgedWindowManagementOperationSpacersResult, SLSBridgedWindowManagementOperationStringResult, SLSBridgedWindowManagementOperationStringsResult, SLSBridgedWindowManagementOperationWindowIDResult, SLSBridgedWindowManagementOperationWorkspaceTypeResult, SLSSynchronousBridgedWindowManagementOperation, SLSWMBridgedWindow, SLSWMBridgedWindowChildInfo
- `classes-total`: 303
- `image`: /System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight header 0x1a0dab000 slide 0x19d18000 entries 33020
- `method-bridgedExported`: not available: SkyLight does not export SLSPerformAsynchronousBridgedWindowManagementOperation (dlsym returns nil)
- `method-bridgedScanned`: available: internal function __ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation at 0x1a0f71c38 (unslid 0x187259c38, not exported), found in SkyLight's symbol table
- `method-compatID`: available: SLSSpaceSetCompatID and SLSSetWindowListWorkspace are exported (reported not to work on recent macOS)
- `method-legacy`: available: SLSMoveWindowsToManagedSpace is exported (known to do nothing since macOS 14.5)
- `methods-SLSAsynchronousBridgedWindowManagementOperation`: SLSAsynchronousBridgedWindowManagementOperation -_init imp 0x1a0f932a0
SLSAsynchronousBridgedWindowManagementOperation -encodeWithCoder: imp 0x1a0f93370
SLSAsynchronousBridgedWindowManagementOperation -initWithCoder: imp 0x1a0f93308
SLSAsynchronousBridgedWindowManagementOperation -invokeFallback imp 0x1a0f9337c
SLSAsynchronousBridgedWindowManagementOperation -performWithWMBridgeDelegate imp 0x1a0f71b4c
SLSAsynchronousBridgedWindowManagementOperation +supportsSecureCoding imp 0x1a0f93374
- `methods-SLSBridgedMoveWindowsToManagedSpaceOperation`: SLSBridgedMoveWindowsToManagedSpaceOperation -.cxx_destruct imp 0x1a0f9dc70
SLSBridgedMoveWindowsToManagedSpaceOperation -encodeWithCoder: imp 0x1a0f9dba4
SLSBridgedMoveWindowsToManagedSpaceOperation -initWithCoder: imp 0x1a0f9d950
SLSBridgedMoveWindowsToManagedSpaceOperation -initWithWindows:spaceID: imp 0x1a0f9d86c
SLSBridgedMoveWindowsToManagedSpaceOperation -invokeFallback imp 0x1a0f9dc24
SLSBridgedMoveWindowsToManagedSpaceOperation -spaceID imp 0x1a0f9dc68
SLSBridgedMoveWindowsToManagedSpaceOperation -windows imp 0x1a0f9dc5c
SLSBridgedMoveWindowsToManagedSpaceOperation +supportsSecureCoding imp 0x1a0f9dc1c
SLSAsynchronousBridgedWindowManagementOperation -_init imp 0x1a0f932a0
SLSAsynchronousBridgedWindowManagementOperation -encodeWithCoder: imp 0x1a0f93370
SLSAsynchronousBridgedWindowManagementOperation -initWithCoder: imp 0x1a0f93308
SLSAsynchronousBridgedWindowManagementOperation -invokeFallback imp 0x1a0f9337c
SLSAsynchronousBridgedWindowManagementOperation -performWithWMBridgeDelegate imp 0x1a0f71b4c
SLSAsynchronousBridgedWindowManagementOperation +supportsSecureCoding imp 0x1a0f93374
- `methods-SLSWindowManagementFallbackBridge`: SLSWindowManagementFallbackBridge -.cxx_destruct imp 0x1a0f73a30
SLSWindowManagementFallbackBridge -init imp 0x1a0f7388c
SLSWindowManagementFallbackBridge -performAsynchronousBridgedWindowManagementOperation: imp 0x1a0f73a28
SLSWindowManagementFallbackBridge -performSynchronousBridgedWindowManagementOperation: imp 0x1a0f739f8
SLSWindowManagementFallbackBridge -performWindowManagementBridgeTransactionUsingBlock: imp 0x1a0f7394c
- `mode`: probe
- `operation-object`: built SLSBridgedMoveWindowsToManagedSpaceOperation with 0 window(s), space 0 (not performed); spaceID reads back 0; responds to -performWithWMBridgeDelegate: yes
- `perform-function`: __ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation address 0x1a0f71c38 unslid 0x187259c38 local
- `symbols`: ___SLSTransactionMoveWindowsToManagedSpace_block_invoke@0x1a0e55ba8 (local)
_SLSWindowManagementBridgeSetWindowTags@0x1a0f716c0 (local)
__ZL19SLSWMBridgeDelegatev@0x1a0f7183c (local)
___SLSWindowManagementBridgeSetWindowTags_block_invoke@0x1a0f718c8 (local)
-[SLSSynchronousBridgedWindowManagementOperation(SLSWindowManagementBridge) performWithWMBridgeDelegate]@0x1a0f71ae0 (local)
-[SLSAsynchronousBridgedWindowManagementOperation(SLSWindowManagementBridge) performWithWMBridgeDelegate]@0x1a0f71b4c (local)
__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation@0x1a0f71ba8 (local)
__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation@0x1a0f71c38 (local)
___SLSWindowManagementBridgeReorderWindows_block_invoke@0x1a0f71cb8 (local)
___SLSWindowManagementBridgeReorderWindows_block_invoke_2@0x1a0f71d70 (local)
-[SLSWindowManagementFallbackBridge performWindowManagementBridgeTransactionUsingBlock:]@0x1a0f7394c (local)
-[SLSWindowManagementFallbackBridge performSynchronousBridgedWindowManagementOperation:]@0x1a0f739f8 (local)
-[SLSWindowManagementFallbackBridge performAsynchronousBridgedWindowManagementOperation:]@0x1a0f73a28 (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation initWithWindows:spaceID:]@0x1a0f9d86c (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation initWithCoder:]@0x1a0f9d950 (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation encodeWithCoder:]@0x1a0f9dba4 (local)
+[SLSBridgedMoveWindowsToManagedSpaceOperation supportsSecureCoding]@0x1a0f9dc1c (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation invokeFallback]@0x1a0f9dc24 (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation windows]@0x1a0f9dc5c (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation spaceID]@0x1a0f9dc68 (local)
-[SLSBridgedMoveWindowsToManagedSpaceOperation .cxx_destruct]@0x1a0f9dc70 (local)
_SLSWindowServerClientMoveWindowsToManagedSpace@0x1a108b66c (local)
___SLSWindowServerClientMoveWindowsToManagedSpace_block_invoke@0x1a108b774 (local)
__ZL39PKGTransactionMoveWindowsToManagedSpaceP22_PKGTransactionContext@0x1a116d02c (local)
__XMoveWindowsToManagedSpace@0x1a12584f8 (local)
__ZZL19SLSWMBridgeDelegatevE16fallbackDelegate@0x1fe2a8fe8 (local)
__ZL31sWindowManagementBridgeDelegate@0x200145a00 (local)
_SLSMoveWindowsToManagedSpace@0x1a108b5b0
_SLSTransactionMoveWindowsToManagedSpace@0x1a0e55afc
_SLSWindowManagementBridgeSetDelegate@0x1a0f716b0
- `symbols-found`: 30
- `wm-client-window-manager`: present

## switch-probe

File: `switch-probe-20261029-165219.json`  
Result: n/a

Observations:

- `accessibility-trusted`: true
- `desktop-shortcuts-usable`: none
- `display-1`: U32R59x: 4 Spaces, current position 4
- `display-2`: Built-in Retina Display: 2 Spaces, current position 2
- `hotkey-79`: enabled; Ctrl+Left (keycode 123, flags 0x840000); plist entry, default combo
- `hotkey-81`: enabled; Ctrl+Right (keycode 124, flags 0x840000); plist entry, default combo
- `macos`: 27.0.1
- `method-keys`: usable: Ctrl+Left / Ctrl+Right are enabled (hotkeys 79 and 81)
- `method-number`: not usable: no "Switch to Desktop n" shortcut (hotkeys 118-133) is enabled; tick them in System Settings > Keyboard > Keyboard Shortcuts > Mission Control
- `method-sls`: usable: SLSManagedDisplaySetCurrentSpace found, with SLSShowSpaces / SLSHideSpaces; expected to change state without repainting
- `method-swipe`: usable: posts a synthetic Dock swipe, modern variant (IOHID payload) on macOS 27; Mission Control may still ignore it
- `natural-scrolling`: true
- `skylight-loaded`: true
- `swipe-variant`: modern
- `symbol-SLSCopyManagedDisplayForSpace`: present
- `symbol-SLSHideSpaces`: present
- `symbol-SLSMainConnectionID`: present
- `symbol-SLSManagedDisplaySetCurrentSpace`: present
- `symbol-SLSShowSpaces`: present

## order-file-apply

File: `order-file-apply-20261029-165230.json`  
Result: FAIL

Observations:

- `backup-file`: /Users/ali/Works/windows_manager/lab-results/backups/com.apple.spaces-20261029-165230.plist
- `display`: 37D8832A-2D66-02CA-B9F7-8F30A301B230
- `display-live-identifier`: 37D8832A-2D66-02CA-B9F7-8F30A301B230
- `dock-pid-after`: 18508
- `dock-pid-before`: 730
- `fullscreen-left-of-desktop1-before`: false
- `fullscreen-left-of-desktop1-requested`: true
- `live-after`: D1[13] | FS:Code[32]
- `live-matches-expected`: false
- `mru-spaces`: false
- `order-argument`: 2,1
- `ordering-entry`: 37D8832A-2D66-02CA-B9F7-8F30A301B230
- `other-displays-unchanged`: true
- `seconds-until-dock`: 0.2
- `seconds-until-spaces`: 0.2
- `space-set-intact`: true
- `spaces-before`: D1[13] | FS:Code[32]
- `spaces-expected`: FS:Code[32] | D1[13]
- `stored-after-restart-kept`: true
- `stored-after-restart-monitors`: FS:Code[32] | D1[13]
- `stored-after-restart-ordering`: FS:Code[32] | D1[13]
- `stored-after-restart-reverted`: false
- `stored-after-write-matches`: true
- `uuids-before`: D5C58298-6128-EB52-F266-30F5D656251E,51C4C534-5079-44A4-A99A-569738BE79D4
- `uuids-expected`: 51C4C534-5079-44A4-A99A-569738BE79D4,D5C58298-6128-EB52-F266-30F5D656251E
- `uuids-live-after`: D5C58298-6128-EB52-F266-30F5D656251E,51C4C534-5079-44A4-A99A-569738BE79D4
- `verdict`: ignored

## order-file-restore

File: `order-file-restore-20261029-165247.json`  
Result: PASS

Observations:

- `backup-file`: /Users/ali/Works/windows_manager/lab-results/backups/com.apple.spaces-20261029-165230.plist
- `displays-compared`: 2
- `live-matches-backup`: true
- `pre-restore-backup`: /Users/ali/Works/windows_manager/lab-results/backups/com.apple.spaces-20261029-165247.plist
- `seconds-until-dock`: 0.5
- `seconds-until-spaces`: 0.5
- `stored-after-restart-matches-backup`: true

## Run notes (2026-10-29, macOS 27.0.1, Stage Manager ON)
- Read-only probes (doctor, spaces, move/switch/virtual --probe, order-file show, ax-remote --app Arc) all ran; Accessibility trusted.
- order-file apply (swap on the built-in display): FAIL, the file keeps the new order but the Dock ignores it at startup. Restore from backup: PASS (live order equals the backup). Decision: do not use the order file to reorder Spaces.
- ax-remote: remote-token lookup works for a window on a full-screen Space (Arc window 114, element 43).
- move --self-test could not run: each display has one Desktop, so no target Desktop exists without adding one by hand in Mission Control.
