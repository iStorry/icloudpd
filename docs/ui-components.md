# UI components: what is custom, what is native

"Native" here means a stock SwiftUI or AppKit control drawn by the system (a `Toggle`, a `Picker`, a `List`). "Custom" means we draw it ourselves from shapes, text and gestures. Custom pieces are where the app's look comes from, but each one is ours to keep working: keyboard focus, VoiceOver, light mode, right-to-left text and animation are all on us.

As of 26 November 2026 (branch `gallery-home`).

## At a glance

- **36 custom views and styles** across 11 files.
- **2 are unused leftovers:** `SwitchRow` and `ProgressRing` (Theme.swift). Safe to delete.
- **1 system hack:** `WindowButtonsPlacer` moves the window's close, minimise and zoom buttons.
- Most real controls inside the custom pieces are already native: switches, menus, date pickers, steppers, text fields, checkboxes.

## Shared building blocks

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| `panel(…)` modifier | Theme.swift | Translucent rounded card with a hairline edge | `GroupBox`, `.background(.regularMaterial)`, or `.glassEffect()` (macOS 26) | Used almost everywhere; it is the app's look. |
| `sidebarColumn(width:)` | Theme.swift | The floating left panel (sidebar, setup steps) | `NavigationSplitView` + `List(.sidebar)` | Native split view was tried and rejected as not premium enough. |
| `PillButtonStyle` | Theme.swift | Blue, grey and red capsule buttons | `.buttonStyle(.borderedProminent)` / `.bordered`, `.glass` / `.glassProminent` (macOS 26), with `.controlSize(.large)` | 15 uses. |
| `HeroButtonStyle` | HomeView.swift | Big white and smoky capsule buttons (Sync Now, Continue, Start) | Same as above | 22 uses. |
| `CircleIcon` | Theme.swift | Round icon button (album picker reload) | `Button` with `.buttonBorderShape(.circle)` and `.bordered` | 1 use. |
| `SectionHeader` | Theme.swift | Small capitals title above a card | `Section("…")` header in a `Form` | |
| `Card`, `CardRow`, `CardDivider` | Theme.swift, HomeView.swift | Card with rows split by hairlines | `Form { Section { … } }.formStyle(.grouped)` | The grouped `Form` draws the same thing natively. |
| `LabeledField` | Theme.swift | Text field in a rounded well with a label above (sign-in) | `TextField` with `.textFieldStyle(.roundedBorder)`, or in a `Form` | The field inside is native; only the well is custom. |
| `ErrorBanner` | Theme.swift | Red rounded message | `Label` in a `GroupBox`, or an `.alert` | |
| `HeroTile`, `IconTile`, `AuthIcon` | Theme.swift, HomeView.swift, AuthViews.swift | Symbol on a tinted rounded square | None (decoration) | Fine to keep. |
| `ProgressRing` | Theme.swift | Circular progress track | `ProgressView(value:).progressViewStyle(.circular)` or `Gauge` | **Unused.** Delete. |
| `SwitchRow` | Theme.swift | Label with a switch | `Toggle` in a `Form` | **Unused.** Delete. |

## Window and sidebar

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| `WindowButtonsPlacer` | WindowButtons.swift | Moves the traffic lights inside the corner panel and puts them back after every resize | `NavigationSplitView` places them inside its sidebar on macOS 26 | **AppKit hack**: reaches into the title bar's private view tree. Could break with a macOS update. |
| `AppSidebar` | HomeView.swift | The main sidebar: pages, Settings sub-menu, sliding highlight | `List(selection:)` with `.listStyle(.sidebar)` and a collapsible `Section` | Highlight slides with `matchedGeometryEffect`; sub-menu folds by animating its height. |
| `RunBadge` | ActivityView.swift | Percentage and small ring next to Activity | `ProgressView(value:)` with `.controlSize(.small)` | |
| Account card | HomeView.swift | Avatar, name and Apple ID | The **menu** behind it is a native `Menu` | Only the label is custom. |
| Space panel | HomeView.swift | "234 GB free of 494 GB" with a bar | `Gauge(value:)` with `.gaugeStyle(.linearCapacity)` | The capacity gauge is made for exactly this. |

## Sign-in and verification

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| `AuthShell`, `AuthPhotoPanel`, `PhotoWall` | AuthViews.swift, HomeView.swift | Photo wall beside the form | None | The look of the app; keep. |
| `AuthHeading` | AuthViews.swift | Eyebrow, title and line under it | Plain `Text` | Just a layout helper. |
| Six code boxes | AuthViews.swift | One box per digit, drawn over one hidden real `TextField` | A single `TextField` | Typing, paste and code autofill still go through the native field. |
| `AccountChip` | AuthViews.swift | Apple ID pill in the corner | None | Decoration. |

## Home

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| Hero (photo wall, status, buttons) | HomeView.swift | Photo wall with headline and Sync Now / Preview | None | The look of the app; keep. |
| `StatusDot` | HomeView.swift | Coloured dot with "Up to date" | `Label` with a tinted SF Symbol | |
| `HomeCard`, `CardLink` | HomeView.swift | "Your plan" and "Your photos" cards with a text link | `GroupBox` and `Button` with `.buttonStyle(.link)` | |
| `WelcomeStage`, `HowItWorks` | HomeView.swift | First-launch screen | None | Content, not controls. |
| `SyncChoiceStage`, `BigChoice` | SyncChoice.swift | "Same as last time" / "Change something" cards | `Picker(.radioGroup)` plus a button, or two `Button`s | Big clickable cards are the point here; keep. |

## Easy setup

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| Step list and progress bar | SetupView.swift | Steps with ticks; thin bar across the top | `ProgressView(value:)` for the bar | |
| `GoalCard`, `PresetCard` | SetupView.swift | Large and small choice cards | `Picker(.radioGroup)` / `.segmented` | Cards read better for this; keep. |
| `RangeBar` | SetupView.swift | Bar showing what moves and what stays | None | Explanation graphic. |
| `SummaryRow` | SetupView.swift | Review row with a Change link | `LabeledContent` in a `Form` | |
| `OptionRow` | SetupView.swift | Label, detail and menu | `Picker` in a `Form` (shows label and menu natively) | The menu is already native. |
| `DiskBar` | SetupView.swift | How full the disk is | `Gauge(.linearCapacity)` | |
| "Quality and folders" disclosure | SetupView.swift | Hand-made fold-out | `DisclosureGroup` | |

## Settings

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| `SettingsSection`, `SettingRow` | SettingsView.swift | Titled card of rows with title and detail | `Form { Section { … } }.formStyle(.grouped)` with `LabeledContent` | Biggest easy win: the grouped form looks very close and handles focus and VoiceOver. |
| `SettingSwitch`, `SettingPicker`, `SettingStepper` | SettingsView.swift | Rows around a control | `Toggle`, `Picker`, `Stepper` placed straight in a `Form` | The controls inside are already native. |
| `ChoiceRow` | SettingsView.swift | Keep / Remove radio rows | `Picker(…).pickerStyle(.radioGroup)` | |
| `FieldWell`, `OptionalNumberRow` | SettingsView.swift | Text field in a rounded well | `TextField` with `.roundedBorder` in a `Form` | |
| `PlanSummary` | SettingsView.swift | Sentence and bar at the top of Free up iCloud | None | Explanation graphic. |
| `IncludeChip` | HomeView.swift | Photos / Videos / … on-off capsules | `Toggle` with `.toggleStyle(.button)` | |
| Album picker rows and search | Views.swift | Card rows with a tick; hand-made search field | `List` with selection or checkbox `Toggle`s; `.searchable` | The sheet itself is native. |

## Activity

| Custom piece | File | What it is | Native alternative | Notes |
|---|---|---|---|---|
| `StatusBadge` | ActivityView.swift | Big round symbol (working, done, stopped…) | None | Decoration. |
| Progress bar | ActivityView.swift | Big blue bar with percentage | `ProgressView(value:)` (linear) | Native bar is thin and can't be restyled much. |
| Results list, problem card | ActivityView.swift | Sentences with icons; amber card with Try Again | `Label`s in a `GroupBox` | |
| `SavedThumbnail` strip | ActivityView.swift | Newest saved photos | None | Content. |
| "Show details" | ActivityView.swift | Hand-made fold-out for the log | `DisclosureGroup` | |
| `ActivityList` | Views.swift | Log lines in a card | `List` or `Table` | |

## Already native

- **Controls:** `Toggle` (switch and checkbox), `Picker` (menu), `DatePicker`, `Stepper`, `TextField`, `SecureField`, `Menu`, `Button` actions, `ProgressView` spinners.
- **Containers and windows:** `ScrollView`, `.sheet` (album picker), `.confirmationDialog` (remove from iCloud), `MenuBarExtra`, the `Window` scene and its ⌘, command.
- **Files:** `NSOpenPanel` folder picker, `NSWorkspace` to open the folder in Finder.

## Where switching to native pays off most

1. **Settings rows → grouped `Form`.** Close to the same look, and native focus, keyboard and VoiceOver come free.
2. **Hand-made fold-outs → `DisclosureGroup`** ("Quality and folders", "Show details").
3. **Space panel and disk bar → `Gauge(.linearCapacity)`.**
4. **Album search → `.searchable`.**
5. **Delete `SwitchRow` and `ProgressRing`.**

Keep custom: the photo walls, hero, sidebar look, big choice cards and button styles. They carry the premium look the native versions lack.
