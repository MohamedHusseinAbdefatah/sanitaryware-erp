#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// Only one copy of the program may run: two copies writing the same
// database at once, or both backing up on close, is untested territory.
// The window title is the Arabic app title set from Dart (Strings.appTitle).
// Arabic text is written as character codes: the compiler reads this file
// in the local code page, so raw Arabic letters would turn into garbage.
static const wchar_t kInstanceMutex[] = L"Local\\SanitarywareERP.SingleInstance";
static const wchar_t kWindowTitle[] = {  // "Idarat al-adawat al-sihhiya"
    0x0625, 0x062F, 0x0627, 0x0631, 0x0629, 0x0020, 0x0627, 0x0644, 0x0623, 0x062F,
    0x0648, 0x0627, 0x062A, 0x0020, 0x0627, 0x0644, 0x0635, 0x062D, 0x064A, 0x0629, 0};
static const wchar_t kAlreadyOpen[] = {  // "The program is already open."
    0x0627, 0x0644, 0x0628, 0x0631, 0x0646, 0x0627, 0x0645, 0x062C, 0x0020, 0x0645,
    0x0641, 0x062A, 0x0648, 0x062D, 0x0020, 0x0628, 0x0627, 0x0644, 0x0641, 0x0639,
    0x0644, 0x002E, 0};

// Returns the mutex if this is the only copy, or nullptr after bringing the
// running copy's window to the front. After a restore the program starts a
// fresh copy of itself with --after-restart; that copy waits for the old
// one to finish exiting instead of giving up.
static HANDLE ClaimSingleInstance(const wchar_t* command_line) {
  const bool after_restart = wcsstr(command_line, L"--after-restart") != nullptr;
  for (int attempt = 0; attempt < (after_restart ? 50 : 1); ++attempt) {
    HANDLE mutex = ::CreateMutexW(nullptr, FALSE, kInstanceMutex);
    if (mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS) {
      return mutex;
    }
    if (mutex != nullptr) ::CloseHandle(mutex);
    if (after_restart) ::Sleep(200);
  }
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (existing != nullptr) {
    if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
    ::SetForegroundWindow(existing);
  } else {
    ::MessageBoxW(nullptr, kAlreadyOpen, kWindowTitle,
                  MB_OK | MB_ICONINFORMATION | MB_RTLREADING | MB_RIGHT);
  }
  return nullptr;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex = ClaimSingleInstance(command_line);
  if (instance_mutex == nullptr) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"sanitaryware_erp", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
