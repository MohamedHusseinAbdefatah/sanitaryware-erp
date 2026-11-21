# UI/UX upgrade (2.5.0): audit, changes, suggestions

## Audit findings (before)

- 159 Dart files, ~46k lines. Shared building blocks already existed
  (`DataList`, `PageHeader`, `RecordPage`, `DocumentView`, `SummaryStrip`,
  `StatusPill`), so the upgrade works through them instead of page by page.
- Colours were tokenised (`AppColors`) but spacing, radii, shadows and
  component themes were not; ~130 inline font sizes.
- Sidebar: fixed 236 px, no folding, no narrow-window mode; groups could
  not be folded; selected item only lightly tinted.
- No way to jump to a page or record without clicking through lists.
- Tables could not be sorted; empty tables showed a bare grey icon.
- Toasts were plain text; several deletions had no confirmation.
- A few raw colours (`Colors.orange/red/green`) outside the theme.
- RTL: layout was already right-to-left with the scrollbar forced to the
  right (2.4.0); arrows already pointed the RTL way.

## What changed

| Area | Change |
|---|---|
| Tokens | `AppColors` (+ brandSoft, borderStrong, subtle, neutral, chart series), `AppSpace`, `AppRadius`, `AppShadows`, `AppMotion`, `Tone` |
| Theme | buttons, segmented, fields (error/focus/hover), dialogs, menus, dropdowns, tabs, chips, checkbox/switch/radio, progress, badge, drawer, date picker, tooltip, snackbar, list tiles; focus ring |
| Shell | full / icon rail / drawer by width; fold with Ctrl+B (remembered); foldable groups; lit edge on open page; tooltips in rail mode |
| Top bar | back + breadcrumb, quick search button, "إنشاء" menu (by role), F1 help, new sale |
| Quick search | `GlobalSearchService` + `command_palette.dart`; keyboard: ↑ ↓ Enter Esc |
| Shared widgets | `EmptyState`, `LoadingState`, `ErrorState`, `FormSection` (states.dart); `confirmAction`; typed `showToast` |
| DataList | sortable headings (`sortValue`), row count footer, hover, empty state with hint/action |
| PageHeader | icon + subtitle, stacks on narrow widths |
| Modules | dashboard attention panel and cards; price-list state icons and edge; totals emphasis in sale/purchase entry; record-page figure tiles; settings header and tab icons; sort keys on products, inventory, customers, suppliers, sales, purchases, payments, cheques, returns, projects |

Business logic, calculations, permissions, routes and the database are
unchanged. The only new behaviour is UI: confirmations before four
deletions, sorting, the quick search (read-only) and the sidebar fold
setting (stored as `ui.sidebar_collapsed` in app settings).

## Suggested next (not done, needs the owner's decision)

- Column show/hide per table (needs a saved per-user layout).
- Split the 1,900-line price-lists screen into files per tab.
- Replace the remaining inline font sizes with text-theme styles.
- Dark mode (tokens are ready; needs a second colour set and testing).
- Saved filters per user on the big lists.
