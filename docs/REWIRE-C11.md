# C11 rewire of app screens onto Core services (P6.113)

Audit of `Sources/WindowsManagerApp` against `Sources/WMCore/Services` (ProfileService, LayoutService, RuleService, LaunchOrderService, SettingsStore). Before this step no app file used a service; screens called `ProfileStore`, `LayoutStore` and the rule stores directly.

## Rewired (behaviour preserving)

- `AppState.profileService`: one `ProfileService` over the app's `ProfileStore`.
- Settings > Profiles: delete (`ProfileService.delete`), export (`show` + `exportData`), import (`importData`, which applies the same unique-name rule as before against the store's names).
- Run already uses `RestoreEngine().run/preview` exactly as `wm run/plan` do; capture already uses `ProfileCapture` and `CaptureSelection` as `wm capture` does. Nothing to change.

## Leftovers (equivalence unclear, not changed)

- Settings > Profiles rename: `ProfileService.rename` rejects a name another profile already uses; the screen allows it today.
- Settings > Profiles duplicate: `ProfileService.copy` makes the name unique ("X copy 2"); `store.duplicate` always gives "X copy".
- `AppState.commitCapture` / `saveSelectiveCapture` save through `store.save` with `ProfileTransfer.uniqueName`; the CLI rejects an existing name instead. No service method for "capture and save", and the two differ on purpose.
- `AppState.run` / `loadScopeChoices` / Studio and Builder models load by id with `store.load`; `ProfileService.show` resolves via a full `list()` per call (O(n^2) in the scope loop) and changes the not-found message.
- `ProfileBuilderModel`, `StudioSaveSheet` (replace-on-conflict delete) and `ProfileStudioModel` save whole profiles with `store.save`; ProfileService works through `ProfileDraftEditor` per edit. Studio layout is out of scope.
- `LayoutEditorModel` (`store.load/upsert/delete`): service validates zones and errors on a missing layout on delete; the editor saves whole in-memory layouts.
- `WindowRulesModel`, `PinRulesModel`, `PinWatcher`, `AutoProfileController`: persist whole rule sets via the stores; `RuleService` works per rule with validation.
- `DisplayMap.current()` in several screens and `SpaceGuardView` (`DriftWatcher`, `SpaceGuard`) are already Core types; no service wraps them.
