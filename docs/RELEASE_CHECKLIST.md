# Release checklist

Do every step, every release. Each one exists because something can go
wrong there that the code alone does not show.

## 1. Before building

- [ ] Version raised in `lib/core/version.dart` and `pubspec.yaml`
      (`1.0.2` and `1.0.2+3`), and a `CHANGELOG.md` entry written.
- [ ] If a table or column changed: `latestSchemaVersion` raised in
      `lib/core/db/database.dart`, an `onUpgrade` step added, and a case added
      to `test/acceptance/upgrade_test.dart` that starts from the previous
      schema and checks the data is still there.
- [ ] Never change these without an upgrade step and test: the data folder
      (`lib/core/db/data_dir.dart`), the database file name, the `AppId` in
      `installer/sanitaryware_erp.iss`.

## 2. Build

- [ ] Run `build_release.bat`. It refuses to build if any test fails.
      The tests include:
      - `test/acceptance/manual_script_test.dart`: the plan's full script
        with hand-calculated totals.
      - `test/acceptance/upgrade_test.dart`: old data opens in the new
        version, same users, passwords, stock and balances.
      - `test/acceptance/performance_test.dart`: a busy year stays fast.

## 3. Upgrade test with the real installer (this PC)

- [ ] Install the **previous** release's setup.exe (keep every release in
      `dist/`).
- [ ] Log in, enter a product, a credit sale and a payment. Close.
- [ ] Install the **new** setup.exe over it, without uninstalling.
- [ ] Open: you get the login (not the setup screen), the same user and
      password work, and the sale, stock and balance are there.

## 4. Clean PC (a second PC or a Windows virtual machine)

- [ ] Install, set up, make a sale, print, back up, restore.
- [ ] Open the program twice: the second time the first window comes to
      the front.

## 5. At the client

- [ ] Before updating: Settings, Backup now, and copy the newest zip from
      the backups folder to your USB drive.
- [ ] Install the update, open it, check the login and the latest sale.
- [ ] **Developer admin account**: in Settings, Users, create an admin
      account for yourself with a password only you know (write it in your
      own records, not on the client's PC). If the shop's admin ever forgets
      their password, you log in with yours and reset theirs from the Users
      screen, without taking their database away.

## 6. When the client reports a problem

1. Ask for two files from `%APPDATA%\SanitarywareERP`:
   - the newest zip in `backups\`
   - `logs\errors.log` (what failed, when, in which version, where in the code)
2. On your PC: Settings, Restore from file, open their backup, and reproduce
   the problem yourself.
3. Write a test that fails because of the problem, fix the code until it
   passes, then release a new version with this checklist.
4. Never edit their database by hand. If data must be corrected, do it
   with the program (cancel and re-enter), so the audit log stays true.
