// AC8 Integrated.exe (2.5.0): a Windows-subsystem launcher, so the player tool opens like a normal application without
// a console window. Next to Host.ps1 (the installed app's root) it runs "Host.ps1 -Action Gui"; next to
// Launcher-GUI.ps1 (a portable package or an installed version folder) it runs the launcher directly. Windows
// PowerShell 5.1 is started without a console (CREATE_NO_WINDOW); a small splash window shows until a window of that
// process appears (the launcher, or the message it shows when it cannot start), then this program exits.
//   --dry-run <file>   write the resolved command line (or "error: ...") to <file> as UTF-8 and exit (tests).
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

namespace {
const wchar_t kClass[]=L"CreeperUX.AC8Integrated.Splash";
DWORD g_child=0;HANDLE g_process=nullptr;ULONGLONG g_started=0;int g_dpi=96;
bool g_window_seen=false,g_exited=false;DWORD g_exit_code=0;

int scale(int v){return MulDiv(v,g_dpi,96);}
std::wstring module_dir(){
 std::vector<wchar_t> buffer(32768);
 const DWORD n=GetModuleFileNameW(nullptr,buffer.data(),static_cast<DWORD>(buffer.size()));
 std::wstring path(buffer.data(),n);const auto cut=path.find_last_of(L"\\/");
 return cut==std::wstring::npos?std::wstring(L"."):path.substr(0,cut);
}
bool file_exists(const std::wstring& path){const DWORD a=GetFileAttributesW(path.c_str());return a!=INVALID_FILE_ATTRIBUTES&&!(a&FILE_ATTRIBUTE_DIRECTORY);}
std::wstring powershell_path(){
 wchar_t system[MAX_PATH]{};const UINT n=GetSystemDirectoryW(system,MAX_PATH);
 return std::wstring(system,n)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
}
struct Plan{std::wstring command,directory,error;};
Plan resolve(){
 Plan plan;plan.directory=module_dir();
 const std::wstring host=plan.directory+L"\\Host.ps1",gui=plan.directory+L"\\Launcher-GUI.ps1";
 std::wstring script,arguments;
 if(file_exists(host)){script=host;arguments=L" -Action Gui";}
 else if(file_exists(gui)){script=gui;}
 else{plan.error=L"找不到 Launcher-GUI.ps1。请从完整解压的整合包或安装目录中运行 AC8 Integrated。";return plan;}
 const std::wstring powershell=powershell_path();
 if(!file_exists(powershell)){plan.error=L"找不到 Windows PowerShell：" +powershell;return plan;}
 plan.command=L"\""+powershell+L"\" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \""+script+L"\""+arguments;
 return plan;
}
bool write_utf8(const std::wstring& path,const std::wstring& text){
 const int bytes=WideCharToMultiByte(CP_UTF8,0,text.c_str(),static_cast<int>(text.size()),nullptr,0,nullptr,nullptr);
 std::string data(static_cast<size_t>(bytes),'\0');
 WideCharToMultiByte(CP_UTF8,0,text.c_str(),static_cast<int>(text.size()),data.data(),bytes,nullptr,nullptr);
 const HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
 if(file==INVALID_HANDLE_VALUE)return false;
 DWORD written=0;const BOOL ok=WriteFile(file,data.data(),static_cast<DWORD>(data.size()),&written,nullptr);
 CloseHandle(file);return ok&&written==data.size();
}
BOOL CALLBACK find_child_window(HWND window,LPARAM result){
 DWORD pid=0;GetWindowThreadProcessId(window,&pid);
 if(pid==g_child&&IsWindowVisible(window)){*reinterpret_cast<HWND*>(result)=window;return FALSE;}
 return TRUE;
}
HFONT make_font(int pixels,int weight,const wchar_t* face){
 return CreateFontW(-scale(pixels),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,face);
}
void paint(HWND window){
 // CreeperUX dark tokens: bg #0d1114, text #f4f1eb, muted #a9b0b3, accent #f8b700.
 PAINTSTRUCT ps;const HDC dc=BeginPaint(window,&ps);RECT r;GetClientRect(window,&r);
 const HBRUSH background=CreateSolidBrush(RGB(0x0d,0x11,0x14));FillRect(dc,&r,background);DeleteObject(background);
 const HBRUSH accent=CreateSolidBrush(RGB(0xf8,0xb7,0x00));RECT mark{scale(26),scale(30),scale(30),r.bottom-scale(30)};FillRect(dc,&mark,accent);DeleteObject(accent);
 SetBkMode(dc,TRANSPARENT);
 const HFONT title=make_font(22,FW_SEMIBOLD,L"Segoe UI"),body=make_font(14,FW_NORMAL,L"Microsoft YaHei UI");
 const HGDIOBJ old=SelectObject(dc,title);SetTextColor(dc,RGB(0xf4,0xf1,0xeb));
 RECT line{scale(46),scale(26),r.right-scale(20),scale(60)};DrawTextW(dc,L"AC8 Integrated",-1,&line,DT_LEFT|DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);
 SelectObject(dc,body);SetTextColor(dc,RGB(0xa9,0xb0,0xb3));
 RECT note{scale(46),scale(62),r.right-scale(20),scale(94)};DrawTextW(dc,L"正在打开启动器…",-1,&note,DT_LEFT|DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);
 SelectObject(dc,old);DeleteObject(title);DeleteObject(body);EndPaint(window,&ps);
}
LRESULT CALLBACK splash_proc(HWND window,UINT message,WPARAM wparam,LPARAM lparam){
 switch(message){
 case WM_PAINT:paint(window);return 0;
 case WM_TIMER:{
  HWND found=nullptr;EnumWindows(find_child_window,reinterpret_cast<LPARAM>(&found));
  if(found){g_window_seen=true;SetForegroundWindow(found);DestroyWindow(window);}
  else if(WaitForSingleObject(g_process,0)==WAIT_OBJECT_0){g_exited=true;GetExitCodeProcess(g_process,&g_exit_code);DestroyWindow(window);}
  else if(GetTickCount64()-g_started>90000){DestroyWindow(window);}
  return 0;
 }
 case WM_DESTROY:KillTimer(window,1);PostQuitMessage(0);return 0;
 }
 return DefWindowProcW(window,message,wparam,lparam);
}
void show_error(const std::wstring& text){MessageBoxW(nullptr,text.c_str(),L"AC8 Integrated",MB_OK|MB_ICONERROR|MB_SETFOREGROUND);}
}

int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int){
 int argc=0;LPWSTR* argv=CommandLineToArgvW(GetCommandLineW(),&argc);
 const bool dry_run=argv&&argc>=3&&lstrcmpiW(argv[1],L"--dry-run")==0;
 const Plan plan=resolve();
 if(dry_run){
  const bool written=write_utf8(argv[2],plan.error.empty()?plan.command:L"error: "+plan.error);
  LocalFree(argv);return written?(plan.error.empty()?0:2):3;
 }
 if(argv)LocalFree(argv);
 if(!plan.error.empty()){show_error(plan.error);return 2;}

 STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
 std::vector<wchar_t> command(plan.command.begin(),plan.command.end());command.push_back(L'\0');
 if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,plan.directory.c_str(),&startup,&process)){
  show_error(L"无法启动 Windows PowerShell（错误 "+std::to_wstring(GetLastError())+L"）。");return 1;
 }
 AllowSetForegroundWindow(process.dwProcessId);CloseHandle(process.hThread);
 g_process=process.hProcess;g_child=process.dwProcessId;g_started=GetTickCount64();

 const HDC screen=GetDC(nullptr);g_dpi=GetDeviceCaps(screen,LOGPIXELSY);ReleaseDC(nullptr,screen);
 WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.lpfnWndProc=splash_proc;cls.hInstance=instance;cls.lpszClassName=kClass;
 cls.hCursor=LoadCursorW(nullptr,IDC_APPSTARTING);cls.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(1));cls.hIconSm=cls.hIcon;
 RegisterClassExW(&cls);
 POINT cursor{};GetCursorPos(&cursor);MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);
 GetMonitorInfoW(MonitorFromPoint(cursor,MONITOR_DEFAULTTOPRIMARY),&monitor);
 const int width=scale(360),height=scale(124);const RECT& area=monitor.rcWork;
 const HWND splash=CreateWindowExW(WS_EX_TOOLWINDOW,kClass,L"AC8 Integrated",WS_POPUP|WS_BORDER,
  area.left+(area.right-area.left-width)/2,area.top+(area.bottom-area.top-height)/2,width,height,nullptr,nullptr,instance,nullptr);
 if(splash){
  ShowWindow(splash,SW_SHOWNORMAL);UpdateWindow(splash);SetTimer(splash,1,100,nullptr);
  MSG message;while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
 }else{WaitForSingleObject(g_process,90000);}
 // A launcher that ended before showing any window had no chance to report why.
 if(g_exited&&!g_window_seen&&g_exit_code!=0){
  show_error(L"启动器没有打开（退出代码 "+std::to_wstring(g_exit_code)+L"）。\n\n诊断文件在 diagnostics 文件夹中（安装版在安装目录的 data\\diagnostics）。也可以运行整合包中的 Start-GUI.cmd 查看错误。");
 }
 CloseHandle(g_process);
 return 0;
}
