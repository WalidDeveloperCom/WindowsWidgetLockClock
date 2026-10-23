# LockClock - lock-screen style clock attached to the desktop wallpaper
# It sits BEHIND all your apps (like part of the wallpaper) and ignores the mouse.
$Position = "Top"      # "Top" or "Bottom"
$Margin   = 40         # distance from the screen edge in pixels
$Use24h   = $false     # $true for 24-hour time
$ShowSeconds = $true   # $false to hide the seconds

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, IntPtr l, uint f, uint t, out UIntPtr r);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Attach a window to the desktop wallpaper layer. x,y are screen pixels.
    public static bool Embed(IntPtr hwnd, int x, int y) {
        IntPtr progman = FindWindow("Progman", null);
        UIntPtr res;
        SendMessageTimeout(progman, 0x052C, UIntPtr.Zero, IntPtr.Zero, 0, 1000, out res);

        IntPtr parent = IntPtr.Zero, after = IntPtr.Zero;
        IntPtr child = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (child != IntPtr.Zero) {            // newer Windows 11 layout
            parent = progman; after = child;
        } else {                               // classic layout
            IntPtr workerw = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                    workerw = FindWindowEx(IntPtr.Zero, h, "WorkerW", null);
                return true;
            }, IntPtr.Zero);
            if (workerw == IntPtr.Zero) return false;
            parent = workerw;
        }

        int st = GetWindowLong(hwnd, -16);
        st = (st & ~unchecked((int)0x80000000)) | 0x40000000;   // popup -> child
        SetWindowLong(hwnd, -16, st);
        SetParent(hwnd, parent);

        POINT p; p.X = x; p.Y = y;
        ScreenToClient(parent, ref p);
        return SetWindowPos(hwnd, after, p.X, p.Y, 0, 0, 0x0001 | 0x0010 | 0x0040);
    }

    // Move an already-embedded window. x,y are screen pixels.
    public static void Place(IntPtr hwnd, int x, int y) {
        IntPtr parent = GetParent(hwnd);
        if (parent == IntPtr.Zero) return;
        POINT p; p.X = x; p.Y = y;
        ScreenToClient(parent, ref p);
        SetWindowPos(hwnd, IntPtr.Zero, p.X, p.Y, 0, 0, 0x0001 | 0x0004 | 0x0010);
    }
}
"@

[void][Win32]::SetProcessDPIAware()

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="False" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" IsHitTestVisible="False">
  <StackPanel IsHitTestVisible="False">
    <TextBlock x:Name="TimeText"
               FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold"
               FontSize="110" Foreground="White" HorizontalAlignment="Center">
      <TextBlock.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="0" Opacity="0.6" Color="Black"/></TextBlock.Effect>
    </TextBlock>
    <TextBlock x:Name="DateText"
               FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold"
               FontSize="30" Foreground="White" HorizontalAlignment="Center" Margin="0,-14,0,0">
      <TextBlock.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="0" Opacity="0.6" Color="Black"/></TextBlock.Effect>
    </TextBlock>
  </StackPanel>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$timeText = $win.FindName("TimeText")
$dateText = $win.FindName("DateText")

function Update-Clock {
    $now = Get-Date
    $fmt = if ($Use24h) { "HH:mm" } else { "h:mm" }
    if ($ShowSeconds) { $fmt += ":ss" }
    $timeText.Text = $now.ToString($fmt)
    $dateText.Text = $now.ToString("dddd, MMMM d")
}
Update-Clock

# Target position in screen pixels (top/bottom center of the main screen)
function Get-Target {
    $s  = [System.Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleX
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w  = $win.ActualWidth * $s
    $h  = $win.ActualHeight * $s
    $x  = $wa.Left + ($wa.Width - $w) / 2
    $y  = if ($Position -eq "Bottom") { $wa.Bottom - $h - ($Margin * $s) } else { $wa.Top + ($Margin * $s) }
    return @([int]$x, [int]$y)
}

# Click-through, never focused, hidden from Alt+Tab
$win.Add_SourceInitialized({
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    $ex = [Win32]::GetWindowLong($hwnd, -20)
    $ex = $ex -bor 0x20 -bor 0x80000 -bor 0x80 -bor 0x08000000
    [void][Win32]::SetWindowLong($hwnd, -20, $ex)
})

# Attach to the wallpaper layer once the window is visible
$win.Add_Loaded({
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    $t = Get-Target
    $ok = [Win32]::Embed($hwnd, $t[0], $t[1])
    if (-not $ok) {
        # Fallback: plain window (not attached). Should rarely happen.
        $win.Left = $t[0]; $win.Top = $t[1]
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    Update-Clock
    $win.UpdateLayout()
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    $t = Get-Target
    [Win32]::Place($hwnd, $t[0], $t[1])
})
$timer.Start()

# Tray icon = the only way to close it
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information
$tray.Text = "LockClock"
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exit = $menu.Items.Add("Exit LockClock")
$exit.Add_Click({ $tray.Visible = $false; $tray.Dispose(); $win.Close() })
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

$app = New-Object System.Windows.Application
[void]$app.Run($win)