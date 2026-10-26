# Credits

Windows Manager builds on work by other open source authors. This page lists the MIT-licensed projects that the research notes name as sources of code, ideas or techniques.

Sources: [02 landscape](research/02-landscape.md), [03 risks](research/03-risks.md), [04 plan](research/04-plan.md).

## MIT-licensed projects

| Project | Used for | Link |
| --- | --- | --- |
| Rectangle | Window move recipe: size, position, size; turning off AXEnhancedUserInterface during moves | https://github.com/rxhanson/Rectangle |
| monitor-glue | Monitor model: monitors keyed by hardware UUID, frames relative to the monitor, restore on connect, wake and unlock | https://github.com/erango/monitor-glue |
| Hammerspoon (hs.spaces) | Accessibility steps on Mission Control for adding and removing Desktops | https://github.com/Hammerspoon/hammerspoon |
| InstantSpaceSwitcher | Synthetic Dock swipe for switching Desktops | https://github.com/jurplel/InstantSpaceSwitcher |
| InstantSpaces | Desktop switching by synthetic Dock swipe (listed with InstantSpaceSwitcher) | https://github.com/pavlohuk/InstantSpaces |
| AeroSpace | Corner parking idea for virtual workspaces | https://github.com/nikitabobko/AeroSpace |
| OpenMultitouchSupport | Reading raw trackpad touches | https://github.com/Kyome22/OpenMultitouchSupport |
| SpacePigeon | Closest project in scope; studied for its limits | https://github.com/louivers/spacepigeon |
| KeyboardShortcuts | Package listed for hotkeys | https://github.com/sindresorhus/KeyboardShortcuts |
| LaunchAtLogin-Modern | Package listed for launch at login | (no link in the research notes) |
| Sparkle 2 | Package listed for app updates | https://github.com/sparkle-project/Sparkle |
| AXorcist | Package listed as an optional Accessibility wrapper | (no link in the research notes) |

Notes:

- Projects are listed here when the research notes mention them as MIT. The notes do not confirm which code, if any, was copied.
- The list of packages (KeyboardShortcuts, LaunchAtLogin-Modern, Sparkle 2, AXorcist) comes from the landscape notes. Whether each one ends up in the app is decided in the roadmap.
- Projects with other licenses are not listed. The research decision is to read GPL and unlicensed projects only, and not to copy their code.

## License of Windows Manager

Pending. The license choice is task P7.1 (MIT is suggested in the roadmap). When it is decided, this section and the README will be updated.
