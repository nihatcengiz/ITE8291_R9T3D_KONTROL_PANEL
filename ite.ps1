param(
    [Parameter(Position = 0)][string]$Komut = "tani",
    [Parameter(Position = 1)][string]$Arg1 = "",
    [Parameter(Position = 2)][string]$Arg2 = "",
    [int]$Parlaklik = 50,
    [int]$Hiz = 5,
    [switch]$Kaydet,
    [switch]$Gecici,
    [switch]$StatikMod,
    [switch]$ServisYenile,
    [switch]$HizliGuncelle
)

# ITE 8291 rev 0.03 (VID 048D / PID 600B, FW 34.3.0.0) - OEM MEZone_3p1nd_102 protokolu (GCUService LM_ITE_RGB)
# Control: 8-byte HID feature report (report id 0)  -> HidD_SetFeature(buf[0]=0, 8 bytes, total 9 bytes)
# Per-key data: 65-byte row buffer on interrupt OUT -> WriteFile / HidD_SetOutputReport (126 LEDs = 504 bytes + 8 zero pad)

$src = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ItePk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(SafeFileHandle h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetFeature(SafeFileHandle h, byte[] b, int n);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int n);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetOutputReport(SafeFileHandle h, byte[] b, int n);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern int HidP_GetCaps(IntPtr p, out HIDP_CAPS c);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref int inBuf, int inSize, out byte outBuf, int outSize, out int ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int ret, IntPtr ov);

    public static int ReadEcByte(SafeFileHandle ecHandle, int addr) {
        if (ecHandle == null || ecHandle.IsInvalid) return -1;
        byte val = 0; int ret = 0;
        if (DeviceIoControl(ecHandle, 0x9C40A488u, ref addr, 4, out val, 1, out ret, IntPtr.Zero)) return val;
        return -1;
    }

    public static bool WriteEcByte(SafeFileHandle ecHandle, int addr, byte val) {
        if (ecHandle == null || ecHandle.IsInvalid) return false;
        byte[] inB = new byte[8];
        Buffer.BlockCopy(BitConverter.GetBytes(addr), 0, inB, 0, 4);
        inB[4] = val;
        byte[] outB = new byte[4];
        int ret = 0;
        return DeviceIoControl(ecHandle, 0x9C40A48Cu, inB, 8, outB, 4, out ret, IntPtr.Zero);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }
}
'@
if (-not ('ItePk' -as [type])) { Add-Type -TypeDefinition $src }

# --- Locate device interface (MI_01 = lighting interface) ---
$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'HID\VID_048D&PID_600B&MI_01*' } | Select-Object -First 1
if (-not $dev) { Write-Host "[HATA] ITE 8291 (048D:600B MI_01) bulunamadi." -ForegroundColor Red; exit 1 }
$script:DevPath = '\\?\' + ($dev.InstanceId -replace '\\', '#') + '#{4d1e55b2-f16f-11cf-88cb-001111000030}'
$script:LastBri = 50
$script:LastSav = 0
$script:h = $null
$script:FLen = 9
$script:OLen = 65

function OpenIteDevice {
    # HID handle'i (yeniden) acar. Cihaz koptugunda (hata 1167) tekrar cagrilir.
    $script:h = [ItePk]::CreateFile($script:DevPath, [uint32]3221225472, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($script:h.IsInvalid) { return $false }
    $pp2 = [IntPtr]::Zero
    $caps2 = New-Object ItePk+HIDP_CAPS
    [void][ItePk]::HidD_GetPreparsedData($script:h, [ref]$pp2)
    [void][ItePk]::HidP_GetCaps($pp2, [ref]$caps2)
    [void][ItePk]::HidD_FreePreparsedData($pp2)
    $script:FLen = [int]$caps2.FeatureReportByteLength
    $script:OLen = [int]$caps2.OutputReportByteLength
    return $true
}

# Ilk acilis
if (-not (OpenIteDevice)) {
    Write-Host "[HATA] Cihaz acilamadi (Win32 hata $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." -ForegroundColor Red
    exit 1
}

function Ctrl([byte[]]$payload) {
    # buf[0] = report id 0, then up to 8 command bytes, padded to FeatureReportByteLength
    if (-not $script:h -or $script:h.IsInvalid) { return $false }
    $buf = New-Object byte[] $script:FLen
    for ($i = 0; $i -lt $payload.Length -and ($i + 1) -lt $script:FLen; $i++) { $buf[$i + 1] = $payload[$i] }
    $ok = [ItePk]::HidD_SetFeature($script:h, $buf, $script:FLen)
    if (-not $ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host ("  [!] SetFeature basarisiz (hata {0})" -f $err) -ForegroundColor DarkYellow
    }
    Start-Sleep -Milliseconds 5
    return $ok
}
function GetCtrl {
    if (-not $script:h -or $script:h.IsInvalid) { return $null }
    $buf = New-Object byte[] $script:FLen
    if ([ItePk]::HidD_GetFeature($script:h, $buf, $script:FLen)) { return , $buf[1..($script:FLen - 1)] }
    return $null
}
function OutReport([byte[]]$payload64) {
    # Output report: [report id 0] + 64 data bytes
    if (-not $script:h -or $script:h.IsInvalid) { return $false }
    $buf = New-Object byte[] $script:OLen
    [Array]::Copy($payload64, 0, $buf, 1, [Math]::Min($payload64.Length, $script:OLen - 1))
    $w = [uint32]0
    $ok = [ItePk]::WriteFile($script:h, $buf, [uint32]$script:OLen, [ref]$w, [IntPtr]::Zero)
    if (-not $ok) { $ok = [ItePk]::HidD_SetOutputReport($script:h, $buf, $script:OLen) }
    return $ok
}

# Key -> byte offset of R in the 512-byte frame (G = +1, B = +2). Source: BetterRGB-ITE8291-Adaptive KEYMAP (048D:600B).
$KEYMAP = [ordered]@{
    Esc=21; F1=45; F2=69; F3=93; F4=117; F5=141; F6=165; F7=189; F8=213; F9=237; F10=261; F11=285; F12=309; FnLockCam=333
    PrtSc=357; Del=381; Home=405; PgUp=429; PgDn=453; End=477
    Grave=17; '1'=41; '2'=65; '3'=89; '4'=113; '5'=137; '6'=161; '7'=185; '8'=209; '9'=233; '0'=257; Minus=281; Equals=305; Backspace=353
    NumLock=377; NumpadDiv=401; NumpadMul=425; NumpadMinus=449
    Tab=13; Q=61; W=85; E=109; R=133; T=157; Y=181; U=205; I=229; O=253; P=277; BracketL=301; BracketR=325; Backslash=349
    Numpad7=373; Numpad8=397; Numpad9=421; NumpadPlus=445
    CapsLock=9; A=57; S=81; D=105; F=129; G=153; H=177; J=201; K=225; L=249; Semicolon=273; Quote=297; Enter=321
    Numpad4=369; Numpad5=393; Numpad6=417
    ShiftL=5; ISO_Backslash=53; Z=77; X=101; C=125; V=149; B=173; N=197; M=221; Comma=245; Period=269; Slash=293; ShiftR=341
    Numpad1=365; Numpad2=389; Numpad3=413; NumpadEnter=437
    CtrlL=1; Fn=49; Windows=73; AltL=97; Space=169; AltGr=241; CopilotKey=289; ArrowUp=337; Numpad0=385; NumpadDecimal=409
    ArrowLeft=313; ArrowDown=433; ArrowRight=361
}
$AUX = @{ 5 = 29; 321 = 345 }   # wide keys with a second LED (ShiftL, Enter)

function SendPrelude {
    # OEM LM_ITE_RGB prelude before mode/effect transitions:
    # 1) Clear aux/lightbar state (08 05 00 00 00 00 00 00)
    # 2) Reset block index 3 (12 00 03 00 00 00 00 00) + 64 zero bytes
    [void](Ctrl @(0x08, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
    [void](Ctrl @(0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00))
    [void](OutReport (New-Object byte[] 64))
}
function EnterCustomMode([byte]$bri, [byte]$sav) {
    # Not: FW 34.3.0.0 (MEZone_3p1nd_102) uzerinde 0x09 (SET_BRIGHTNESS) komutu kullanilmaz;
    # 0x09 gondermek 0x33 (UserMode) ve donanim efektlerini bozar. Parlaklik dogrudan 0x08 0x02 icinde verilir.
    # Canli guncelleme (-HizliGuncelle) sirasinda 08 05 / 12 00 03 prelude tekrar gonderilmez; boylece klavye taramasi kesintiye ugramaz.
    if (-not $HizliGuncelle) {
        SendPrelude
    }
    $script:LastBri = $bri
    $script:LastSav = $sav
    [void](Ctrl @(0x08, 0x02, 0x33, 0x00, $bri, 0x00, 0x00, $sav))
}
function SendFrame([byte[]]$frame) {
    [void](Ctrl @(0x12, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00))
    $chunk = New-Object byte[] 64
    for ($i = 0; $i -lt 8; $i++) {
        [Array]::Copy($frame, $i * 64, $chunk, 0, 64)
        [void](OutReport $chunk)
    }
}
function PutKey([byte[]]$frame, [int]$off, [byte]$r, [byte]$g, [byte]$b) {
    $frame[$off] = $r; $frame[$off + 1] = $g; $frame[$off + 2] = $b
    if ($AUX.ContainsKey($off)) { $a = $AUX[$off]; $frame[$a] = $r; $frame[$a + 1] = $g; $frame[$a + 2] = $b }
}
function PutKeyName([byte[]]$frame, [string]$name, [byte]$r, [byte]$g, [byte]$b) {
    if ($KEYMAP.Contains($name)) {
        PutKey $frame $KEYMAP[$name] $r $g $b
    }
}
function FillFrameBase([byte[]]$frame, [byte]$r, [byte]$g, [byte]$b) {
    for ($i = 0; $i -lt 126; $i++) {
        $off = ($i * 4) + 1
        $frame[$off]     = $r
        $frame[$off + 1] = $g
        $frame[$off + 2] = $b
    }
}
function LerpColor([int[]]$c1, [int[]]$c2, [double]$t) {
    $t = [Math]::Min([Math]::Max($t, 0.0), 1.0)
    return @(
        [byte][Math]::Round($c1[0] + ($c2[0] - $c1[0]) * $t),
        [byte][Math]::Round($c1[1] + ($c2[1] - $c1[1]) * $t),
        [byte][Math]::Round($c1[2] + ($c2[2] - $c1[2]) * $t)
    )
}
function MultiStopGradient([array]$stops, [double]$t) {
    $t = [Math]::Min([Math]::Max($t, 0.0), 1.0)
    $n = $stops.Count - 1
    if ($n -le 0) { return [byte[]]@($stops[0][0], $stops[0][1], $stops[0][2]) }
    $scaled = $t * $n
    $idx = [Math]::Min([int][Math]::Floor($scaled), $n - 1)
    $localT = $scaled - $idx
    return LerpColor $stops[$idx] $stops[$idx + 1] $localT
}
function SetGradientTheme([array]$stops, [byte]$bri, [byte]$sav) {
    $frame = New-Object byte[] 512
    # Her LED'in matris sutun konumuna (offset 1..501) gore soldan saga yumusak gecis
    for ($i = 0; $i -lt 126; $i++) {
        $off = ($i * 4) + 1
        $colPos = [double]([Math]::Floor($i / 6)) / 20.0
        $c = MultiStopGradient $stops $colPos
        $frame[$off]     = $c[0]
        $frame[$off + 1] = $c[1]
        $frame[$off + 2] = $c[2]
    }
    EnterCustomMode $bri $sav
    SendFrame $frame
}

function Set-EcFanMode([string]$Mode, [int]$ManuelYuzde = -1) {
    $ecH = [ItePk]::CreateFile("\\.\ACPIDriver", [uint32]3221225472, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($ecH.IsInvalid) {
        Write-Host "[HATA] EC surucusu (\\.\ACPIDriver) acilamadi!" -ForegroundColor Red
        return $false
    }
    try {
        # EC register haritasi (REA ile GCUService.exe Define.ECSpec'ten dogrulandi):
        #   0x751 = ADDR_MAFAN_CONTROL_BYTE  (mod baytı; EC bit6(0x40)=force-max)
        #   0x75B = ADDR_EC_MAIN_FAN_L_DUTY_BYTE (CPU duty 0..200)
        #   0x75C = ADDR_EC_MAIN_FAN_R_DUTY_BYTE (GPU duty 0..200)
        #   0x767 = ADDR_TRIGGER_BYTE (mod seçici)
        #      Doğrulanmış: 0x00 = NORMAL (EC kendi eğrisi); 0x04 = FORCE-MAX (%100)
        switch ($Mode.ToLower()) {
            "boost" {
                # Toggle: EC'de BOOST aciksa kapatmayi dene, degilse ac.
                $cur = [ItePk]::ReadEcByte($ecH, 0x751)
                $isBoost = ($cur -eq 64 -or $cur -eq 1)
                if ($isBoost) {
                    [void][ItePk]::WriteEcByte($ecH, 0x751, 0)
                    [void][ItePk]::WriteEcByte($ecH, 0x767, 0x00)
                    Start-Sleep -Milliseconds 700
                    $after = [ItePk]::ReadEcByte($ecH, 0x751)
                    if ($after -eq 64 -or $after -eq 1) {
                        Write-Host "[!] EC BOOST modunu kendi kilitliyor (0x751 geri 0x40 oldu)." -ForegroundColor Yellow
                    } else {
                        Write-Host "[OK] Fan Modu: FAN BOOST kapatildi (0x751=0 -> NORMAL)." -ForegroundColor Cyan
                    }
                } else {
                    [void][ItePk]::WriteEcByte($ecH, 0x751, 1)
                    [void][ItePk]::WriteEcByte($ecH, 0x767, 0x04)
                    Write-Host "[OK] Fan Modu: FAN BOOST acildi (0x751=1, tam devir)." -ForegroundColor Green
                }
            }
            "turbo" {
                [void][ItePk]::WriteEcByte($ecH, 0x75B, 180)
                [void][ItePk]::WriteEcByte($ecH, 0x75C, 180)
                [void][ItePk]::WriteEcByte($ecH, 0x767, 0x00)
                Write-Host "[i] Fan: %90 duty istendi (EC bu makinada duty yazimini yok sayabilir)." -ForegroundColor Yellow
            }
            "sessiz" {
                [void][ItePk]::WriteEcByte($ecH, 0x75B, 40)
                [void][ItePk]::WriteEcByte($ecH, 0x75C, 40)
                [void][ItePk]::WriteEcByte($ecH, 0x767, 0x00)
                Write-Host "[i] Fan: %20 duty istendi (EC bu makinada duty yazimini yok sayabilir)." -ForegroundColor Yellow
            }
            "oto" {
                [void][ItePk]::WriteEcByte($ecH, 0x751, 0)
                [void][ItePk]::WriteEcByte($ecH, 0x767, 0x00)
                Write-Host "[OK] Fan Modu: NORMAL (0x751=0, donanim sicaklik egrisi)." -ForegroundColor Green
            }
            "manuel" {
                $pct = if ($ManuelYuzde -gt 0) { $ManuelYuzde } else { 50 }
                if ($pct -lt 20) { $pct = 20 }
                if ($pct -gt 100) { $pct = 100 }
                $duty = [byte]($pct * 2)
                [void][ItePk]::WriteEcByte($ecH, 0x75B, $duty)
                [void][ItePk]::WriteEcByte($ecH, 0x75C, $duty)
                [void][ItePk]::WriteEcByte($ecH, 0x767, 0x00)
                Write-Host ("[i] Manuel Fan Hizi: %{0} (Duty: {1}) istendi; EC yok sayabilir." -f $pct, $duty) -ForegroundColor Yellow
            }
            default {
                Write-Host "Gecerli fan modlari: oto | boost | turbo | sessiz | manuel <yuzde>" -ForegroundColor Yellow
            }
        }
        return $true
    } finally {
        $ecH.Close()
    }
}

function Get-EcSensors {
    $ecH = [ItePk]::CreateFile("\\.\ACPIDriver", [uint32]3221225472, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($ecH.IsInvalid) { return $null }
    try {
        $cpuTemp = [ItePk]::ReadEcByte($ecH, 0x43E)
        $gpuTemp = [ItePk]::ReadEcByte($ecH, 0x46A)
        if ($gpuTemp -le 0) { $gpuTemp = [ItePk]::ReadEcByte($ecH, 0x44F) }
        $f1Hi = [ItePk]::ReadEcByte($ecH, 0x464)
        $f1Lo = [ItePk]::ReadEcByte($ecH, 0x465)
        $f2Hi = [ItePk]::ReadEcByte($ecH, 0x46C)
        $f2Lo = [ItePk]::ReadEcByte($ecH, 0x46B)
        $f1DutyRaw = [ItePk]::ReadEcByte($ecH, 0x75B)
        $f2DutyRaw = [ItePk]::ReadEcByte($ecH, 0x75C)
        $cpuFanRpm = if ($f1Hi -ge 0 -and $f1Lo -ge 0) { ($f1Hi -shl 8) -bor $f1Lo } else { 0 }
        $gpuFanRpm = if ($f2Hi -ge 0 -and $f2Lo -ge 0) { ($f2Hi -shl 8) -bor $f2Lo } else { 0 }
        $cpuFanPct = if ($f1DutyRaw -ge 0) { [int][Math]::Min([Math]::Round($f1DutyRaw / 2.0), 100) } else { 0 }
        $gpuFanPct = if ($f2DutyRaw -ge 0) { [int][Math]::Min([Math]::Round($f2DutyRaw / 2.0), 100) } else { 0 }
        return @{
            CpuTemp   = $cpuTemp
            GpuTemp   = $gpuTemp
            CpuFanRpm = $cpuFanRpm
            GpuFanRpm = $gpuFanRpm
            CpuFanPct = $cpuFanPct
            GpuFanPct = $gpuFanPct
        }
    } finally {
        $ecH.Close()
    }
}

function Get-SystemMetrics([int]$CpuOverride = -1, [int]$RamOverride = -1, [int]$GpuTempOverride = -1, [int]$BatOverride = -1) {
    $ec = Get-EcSensors
    $cpuPct = $CpuOverride
    if ($cpuPct -lt 0) {
        try {
            $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
            if ($p) { $cpuPct = [int]$p.PercentProcessorTime } else { $cpuPct = 15 }
        } catch { $cpuPct = 15 }
    }
    $ramPct = $RamOverride
    if ($ramPct -lt 0) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os -and $os.TotalVisibleMemorySize -gt 0) {
                $ramPct = [int][Math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 100.0) / $os.TotalVisibleMemorySize)
            } else { $ramPct = 40 }
        } catch { $ramPct = 40 }
    }
    $cpuTemp = if ($ec -and $ec.CpuTemp -gt 0) { $ec.CpuTemp } else { 55 }
    $gpuTemp = if ($GpuTempOverride -ge 0) { $GpuTempOverride } elseif ($ec -and $ec.GpuTemp -gt 0) { $ec.GpuTemp } else { $cpuTemp }
    $cpuFanRpm = if ($ec) { $ec.CpuFanRpm } else { 0 }
    $gpuFanRpm = if ($ec) { $ec.GpuFanRpm } else { 0 }
    $cpuFanPct = if ($ec) { $ec.CpuFanPct } else { 0 }
    $gpuFanPct = if ($ec) { $ec.GpuFanPct } else { 0 }
    $batPct = $BatOverride
    $acOnline = $true
    if ($batPct -lt 0) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
            $batPct = [int][Math]::Round($ps.BatteryLifePercent * 100)
            $acOnline = ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online)
        } catch { $batPct = 100 }
    }
    return @{
        Cpu       = [Math]::Min([Math]::Max($cpuPct, 0), 100)
        Ram       = [Math]::Min([Math]::Max($ramPct, 0), 100)
        CpuTemp   = [Math]::Min([Math]::Max($cpuTemp, 20), 110)
        GpuTemp   = [Math]::Min([Math]::Max($gpuTemp, 20), 110)
        CpuFanRpm = $cpuFanRpm
        GpuFanRpm = $gpuFanRpm
        CpuFanPct = $cpuFanPct
        GpuFanPct = $gpuFanPct
        Battery   = [Math]::Min([Math]::Max($batPct, 0), 100)
        AcPower   = $acOnline
    }
}

function SetSystemMonitorFrame([string]$mod, [byte]$bri, [byte]$sav) {
    $m = Get-SystemMetrics
    $frame = New-Object byte[] 512
    $tempStops = @(@(0,180,255), @(0,255,140), @(255,215,0), @(255,80,0), @(255,0,0))
    $tempNorm  = ([double]($m.GpuTemp - 35)) / 45.0
    $tempCol1  = MultiStopGradient $tempStops $tempNorm

    $fKeys   = @('F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12')
    $numKeys = @('1','2','3','4','5','6','7','8','9','0','Minus','Equals')

    switch ($mod) {
        "pil" {
            # Soldan saga pil doluluk bari (%0..%100)
            $batT = $m.Battery / 100.0
            $batCol = MultiStopGradient @(@(255,0,0), @(255,180,0), @(0,255,80), @(0,230,255)) $batT
            for ($i = 0; $i -lt 126; $i++) {
                $off = ($i * 4) + 1
                $colPos = [double]([Math]::Floor($i / 6)) / 20.0
                if ($colPos -le $batT) {
                    $frame[$off] = $batCol[0]; $frame[$off + 1] = $batCol[1]; $frame[$off + 2] = $batCol[2]
                } else {
                    $frame[$off] = 12; $frame[$off + 1] = 16; $frame[$off + 2] = 30
                }
            }
            if ($m.AcPower) { PutKeyName $frame 'Esc' 0 255 80 } else { PutKeyName $frame 'Esc' 255 140 0 }
        }
        default {
            # "gosterge" (Varsayilan):
            # - Alt harf blogu: GPU Sicaklik rengi (hafif ton) ve WASD parlak sicaklik rengi
            # - F1..F12: Canli CPU Kullanim Bari (Yesil -> Sari -> Kirmizi)
            # - 1..Equals: Canli RAM Kullanim Bari (Turkuaz -> Mavi -> Mor)
            # - Numpad / Oklar: Pil durumu
            $bgR = [byte][Math]::Round($tempCol1[0] * 0.28)
            $bgG = [byte][Math]::Round($tempCol1[1] * 0.28)
            $bgB = [byte][Math]::Round($tempCol1[2] * 0.28)
            FillFrameBase $frame $bgR $bgG $bgB

            foreach ($k in @('W','A','S','D','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Space','Enter')) {
                PutKeyName $frame $k $tempCol1[0] $tempCol1[1] $tempCol1[2]
            }
            if ($m.AcPower) { PutKeyName $frame 'Esc' 0 255 90 } else { PutKeyName $frame 'Esc' 255 150 0 }

            # CPU Bari: F1..F12
            $cpuBars = [Math]::Max(1, [int][Math]::Ceiling(($m.Cpu / 100.0) * 12))
            for ($i = 0; $i -lt 12; $i++) {
                if ($i -lt $cpuBars) {
                    $c = MultiStopGradient @(@(0,255,80), @(255,220,0), @(255,0,0)) ($i / 11.0)
                    PutKeyName $frame $fKeys[$i] $c[0] $c[1] $c[2]
                } else {
                    PutKeyName $frame $fKeys[$i] 10 14 28
                }
            }

            # RAM Bari: 1..Equals
            $ramBars = [Math]::Max(1, [int][Math]::Ceiling(($m.Ram / 100.0) * 12))
            for ($i = 0; $i -lt 12; $i++) {
                if ($i -lt $ramBars) {
                    $c = MultiStopGradient @(@(0,240,255), @(0,110,255), @(190,0,255)) ($i / 11.0)
                    PutKeyName $frame $numKeys[$i] $c[0] $c[1] $c[2]
                } else {
                    PutKeyName $frame $numKeys[$i] 10 14 28
                }
            }
        }
    }
    EnterCustomMode $bri $sav
    SendFrame $frame
    return $m
}
function SetThemePreset([string]$tema, [byte]$bri, [byte]$sav) {
    $frame = New-Object byte[] 512
    switch ($tema) {
        "oyuncu" {
            # Arka plan: Koyu Gece Moru/Lacivert
            FillFrameBase $frame 20 8 55
            # Yardimci oyun tuslari: Parlak Turkuaz
            foreach ($k in @('Esc','Tab','CapsLock','ShiftL','CtrlL','AltL','Space','Q','E','R','F','G','Z','X','C','V','1','2','3','4','5')) {
                PutKeyName $frame $k 0 230 255
            }
            # Fonksiyon tuslari: Altin Sarisi
            foreach ($k in @('F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','Enter','NumpadEnter')) {
                PutKeyName $frame $k 255 180 0
            }
            # WASD ve Ok Tuslari: Parlak Kirmizi
            foreach ($k in @('W','A','S','D','ArrowUp','ArrowDown','ArrowLeft','ArrowRight')) {
                PutKeyName $frame $k 255 0 0
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "moba" {
            # MOBA (LoL / Dota 2): QWER Turkuaz, DF Altin, 1-6 Yesil, B Mor, Space/Tab Beyaz
            FillFrameBase $frame 12 18 35
            foreach ($k in @('Q','W','E','R')) { PutKeyName $frame $k 0 240 255 }
            foreach ($k in @('D','F')) { PutKeyName $frame $k 255 200 0 }
            foreach ($k in @('1','2','3','4','5','6','7')) { PutKeyName $frame $k 0 255 100 }
            foreach ($k in @('B')) { PutKeyName $frame $k 200 0 255 }
            foreach ($k in @('A','S','X','C','V')) { PutKeyName $frame $k 255 60 0 }
            foreach ($k in @('Esc','Tab','Space','CtrlL','ShiftL','AltL','Enter','F1','F2','F3','F4','F5')) {
                PutKeyName $frame $k 255 255 255
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "siber" {
            # Cyberpunk 2077: Sol/Ust Neon Sari, Orta Siber Pembe, Sag/Numpad Elektrik Turkuazi
            for ($i = 0; $i -lt 126; $i++) {
                $off = ($i * 4) + 1
                $col = [Math]::Floor($i / 6)
                if ($col -lt 6) {
                    $frame[$off] = 255; $frame[$off + 1] = 225; $frame[$off + 2] = 0
                } elseif ($col -lt 14) {
                    $frame[$off] = 255; $frame[$off + 1] = 0; $frame[$off + 2] = 128
                } else {
                    $frame[$off] = 0; $frame[$off + 1] = 240; $frame[$off + 2] = 255
                }
            }
            foreach ($k in @('Esc','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','Space')) {
                PutKeyName $frame $k 255 235 0
            }
            foreach ($k in @('W','A','S','D','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Enter')) {
                PutKeyName $frame $k 0 255 255
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "gunbatimi" {
            $stops = @(@(255,15,0), @(255,95,0), @(255,190,0), @(230,0,130), @(80,0,255))
            SetGradientTheme $stops $bri $sav
        }
        "okyanus" {
            $stops = @(@(0,25,180), @(0,110,255), @(0,240,255), @(0,255,130), @(0,180,255))
            SetGradientTheme $stops $bri $sav
        }
        "atesbuz" {
            $stops = @(@(255,0,0), @(255,90,0), @(255,210,0), @(255,255,255), @(0,220,255), @(0,70,255))
            SetGradientTheme $stops $bri $sav
        }
        "gokkusagisabit" {
            $stops = @(@(255,0,0), @(255,120,0), @(255,230,0), @(0,255,40), @(0,220,255), @(40,60,255), @(220,0,255))
            SetGradientTheme $stops $bri $sav
        }
        "matrix" {
            # Arka plan ve harfler: Matrix Yesili, Kontrol/Fonksiyon tuslari: Parlak Nane Beyazi
            FillFrameBase $frame 0 220 35
            foreach ($k in @('Esc','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12',
                             'Tab','CapsLock','ShiftL','ShiftR','CtrlL','Fn','Windows','AltL','AltGr',
                             'Space','Enter','Backspace','Del','Home','End','PgUp','PgDn',
                             'ArrowUp','ArrowDown','ArrowLeft','ArrowRight')) {
                PutKeyName $frame $k 160 255 180
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "retro" {
            # 80'ler Retro Outrun: Her satir farkli bir neon renk kusagi
            FillFrameBase $frame 140 0 255
            foreach ($k in @('Esc','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','FnLockCam','PrtSc','Del','Home','PgUp','PgDn','End')) {
                PutKeyName $frame $k 255 0 128
            }
            foreach ($k in @('Grave','1','2','3','4','5','6','7','8','9','0','Minus','Equals','Backspace','NumLock','NumpadDiv','NumpadMul','NumpadMinus')) {
                PutKeyName $frame $k 160 0 255
            }
            foreach ($k in @('Tab','Q','W','E','R','T','Y','U','I','O','P','BracketL','BracketR','Backslash','Numpad7','Numpad8','Numpad9','NumpadPlus')) {
                PutKeyName $frame $k 0 110 255
            }
            foreach ($k in @('CapsLock','A','S','D','F','G','H','J','K','L','Semicolon','Quote','Enter','Numpad4','Numpad5','Numpad6')) {
                PutKeyName $frame $k 0 245 255
            }
            foreach ($k in @('ShiftL','ISO_Backslash','Z','X','C','V','B','N','M','Comma','Period','Slash','ShiftR','Numpad1','Numpad2','Numpad3','NumpadEnter')) {
                PutKeyName $frame $k 255 215 0
            }
            foreach ($k in @('CtrlL','Fn','Windows','AltL','Space','AltGr','CopilotKey','ArrowUp','ArrowLeft','ArrowDown','ArrowRight','Numpad0','NumpadDecimal')) {
                PutKeyName $frame $k 255 65 0
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "turkbayragi" {
            # Al-Beyaz: Klavye parlak Al Kirmizi, merkezde Hilal & Yildiz tus grubu Parlak Beyaz
            FillFrameBase $frame 255 0 0
            foreach ($k in @('3','4','5','E','R','D','C','V','B','Y','H','U','J','I')) {
                PutKeyName $frame $k 255 255 255
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "galaksi" {
            # Derin Uzay & Bulutsu: Mor-Lacivert uzay zemini uzerinde yildiz ve bulutsu kumeleri
            $stops = @(@(35,0,90), @(90,0,180), @(180,0,220), @(0,140,255), @(40,0,110))
            for ($i = 0; $i -lt 126; $i++) {
                $off = ($i * 4) + 1
                $colPos = [double]([Math]::Floor($i / 6)) / 20.0
                $c = MultiStopGradient $stops $colPos
                $frame[$off] = $c[0]; $frame[$off + 1] = $c[1]; $frame[$off + 2] = $c[2]
            }
            foreach ($k in @('Esc','F4','F8','F12','2','6','9','W','T','O','A','G','L','Z','B','M','Space','ArrowUp','Numpad5','Numpad9')) {
                PutKeyName $frame $k 255 255 255
            }
            foreach ($k in @('F2','F6','F10','4','8','R','U','P','D','J','Enter','X','N','ArrowLeft','ArrowRight','Numpad7','Numpad3')) {
                PutKeyName $frame $k 0 255 240
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
        "keskin" {
            # Buz Beyazi zemin + Kirmizi Oyuncu Vurgusu
            FillFrameBase $frame 220 235 255
            foreach ($k in @('Esc','W','A','S','D','Space','Enter','NumpadEnter','ArrowUp','ArrowDown','ArrowLeft','ArrowRight')) {
                PutKeyName $frame $k 255 0 0
            }
            EnterCustomMode $bri $sav
            SendFrame $frame
        }
    }
}
function SetAllKeys([byte]$r, [byte]$g, [byte]$b, [byte]$bri, [byte]$sav) {
    if ($StatikMod) {
        SendPrelude
        [void](Ctrl @(0x14, 0x00, 0x01, $r, $g, $b, 0x00, 0x00))
        [void](Ctrl @(0x08, 0x02, 0x01, 0x05, $bri, 0x01, 0x01, $sav))
        return
    }
    $frame = New-Object byte[] 512
    # OEM MEZone_3p1nd_102: 126 LED (126 x 4 = 504 bayt, indeks 0..125 -> [0x00, R, G, B]); son 8 bayt (504..511) 0x00 kalir
    for ($i = 0; $i -lt 126; $i++) {
        $off = ($i * 4) + 1
        $frame[$off]     = $r
        $frame[$off + 1] = $g
        $frame[$off + 2] = $b
    }
    foreach ($off in $KEYMAP.Values) { PutKey $frame $off $r $g $b }
    EnterCustomMode $bri $sav
    SendFrame $frame
}
function SetPalette([array]$p) {
    for ($i = 0; $i -lt [Math]::Min($p.Count, 7); $i++) {
        [void](Ctrl @(0x14, 0x00, [byte]($i + 1), [byte]$p[$i][0], [byte]$p[$i][1], [byte]$p[$i][2], 0x00, 0x00))
    }
}
function DefaultPalette {
    $p = @(@(255,0,0), @(255,28,0), @(255,119,0), @(0,255,0), @(0,0,255), @(0,255,255), @(255,0,255))
    SetPalette $p
}
function NeonPalette {
    # Synthwave / Neon: Siber Pembe, Mor, Elektrik Mavisi, Turkuaz, Macenta
    $p = @(@(255,0,128), @(180,0,255), @(80,0,255), @(0,140,255), @(0,255,240), @(140,0,255), @(255,0,200))
    SetPalette $p
}
function FirePalette {
    # Ates & Lav: Koyu Kirmizi, Parlak Kirmizi, Turuncu, Altin Sarisi
    $p = @(@(255,0,0), @(255,35,0), @(255,80,0), @(255,150,0), @(255,210,0), @(255,70,0), @(255,15,0))
    SetPalette $p
}
function NorthernPalette {
    # Kuzey Isiklari: Derin Mavi, Turkuaz, Zumrut Yesili, Nane, Mor
    $p = @(@(0,60,255), @(0,180,255), @(0,255,200), @(0,255,90), @(0,220,180), @(90,0,255), @(0,120,255))
    SetPalette $p
}
function RoyalPalette {
    # Altin & Kraliyet Moru: Altin Sarisi, Kehribar, Kraliyet Moru, Beyaz Altin, Eflatun
    $p = @(@(255,200,0), @(255,140,0), @(120,0,255), @(180,0,255), @(255,235,120), @(90,0,220), @(255,180,0))
    SetPalette $p
}
function ToxicPalette {
    # Toksik / Biohazard: Radyoaktif Yesil, Asit Sarisi, Zumrut, Koyu Mor
    $p = @(@(0,255,0), @(160,255,0), @(230,255,0), @(0,220,60), @(110,0,255), @(0,255,80), @(180,255,0))
    SetPalette $p
}
function SakuraPalette {
    # Sakura / Kiraz Cicegi: Pembe, Inci Beyazi, Eflatun, Mercan
    $p = @(@(255,40,140), @(255,130,190), @(255,220,240), @(210,70,255), @(255,80,160), @(255,170,210), @(255,20,120))
    SetPalette $p
}
function SyncOemRegistry([int]$oemEffect, [int]$briVal, [int]$spdVal, [int]$dirVal, [byte]$r, [byte]$g, [byte]$b, [bool]$powerOn) {
    # Arka planda calisan GCUService.exe (Kontrol Merkezi) bos kalma zamanlayicisi tetiklendiginde
    # HKLM:\SOFTWARE\OEM\GamingCenter2\RGBKeyboard\MEZone_3p1nd_102 altindaki 26_LastEffect JSON degerini tekrar yukler.
    # save_effect kodlari: 1=Tek Renk (Static), 2=Nefes, 3=Dalga, 5=Gokkusagi (Orijinal), 14=Aurora
    $baseKey = "HKLM:\SOFTWARE\OEM\GamingCenter2\RGBKeyboard"
    $zoneKey = "$baseKey\MEZone_3p1nd_102"
    try {
        if (Test-Path $baseKey) {
            Set-ItemProperty -Path $baseKey -Name "PowerSwitch" -Value ($(if ($powerOn) { 1 } else { 0 })) -ErrorAction Stop
            $lvl = if (-not $powerOn -or $briVal -le 0) { 0 } elseif ($briVal -le 8) { 1 } elseif ($briVal -le 22) { 2 } elseif ($briVal -le 36) { 3 } else { 4 }
            Set-ItemProperty -Path $baseKey -Name "ACLight" -Value $lvl -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $baseKey -Name "DCLight" -Value $lvl -ErrorAction SilentlyContinue
        }
        if (Test-Path $zoneKey) {
            $rawJson = (Get-ItemProperty -Path $zoneKey -Name "26_LastEffect" -ErrorAction SilentlyContinue)."26_LastEffect"
            if ($rawJson) {
                $obj = $rawJson | ConvertFrom-Json
                $obj.save_mode = 1
                $obj.save_effect = $oemEffect
                $obj.save_light = $(if ($powerOn) { $briVal } else { 0 })
                $obj.save_speed = $spdVal
                $obj.save_direction = $dirVal
                $obj.save_power_status = $(if ($powerOn) { 1 } else { 0 })
                if ($oemEffect -eq 1) {
                    $obj.save_layout_color.isCircular = $false
                    $obj.save_layout_color.ColorBlocks = 1
                    if ($obj.save_layout_color.ColorBuffer.Count -gt 0) {
                        $obj.save_layout_color.ColorBuffer[0].R = [int]$r
                        $obj.save_layout_color.ColorBuffer[0].G = [int]$g
                        $obj.save_layout_color.ColorBuffer[0].B = [int]$b
                    }
                } else {
                    $obj.save_layout_color.isCircular = $true
                    $obj.save_layout_color.ColorBlocks = 7
                }
                $newJson = $obj | ConvertTo-Json -Depth 6 -Compress
                Set-ItemProperty -Path $zoneKey -Name "26_LastEffect" -Value $newJson -ErrorAction Stop
            }
        }
        if ($ServisYenile) {
            Restart-OemService
        }
        return $true
    } catch {
        # Yonetici yetkisi yoksa sessizce gec
        return $false
    }
}
function Restart-OemService {
    try {
        $svc = Get-Service -Name "GCUBridge" -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Process -Name "GCUService" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name "GCUBridge" -Force -ErrorAction Stop
            Write-Host "[OK] OEM GCUService yeni kayit defteri ayarlariyla yeniden baslatildi." -ForegroundColor Cyan
        }
    } catch {
        Write-Host "[!] GCUService yeniden baslatilamadi (Yonetici yetkisi gerekli)." -ForegroundColor Yellow
    }
}

$bri = [byte][Math]::Min([Math]::Max($Parlaklik, 0), 50)
$spd = [byte][Math]::Min([Math]::Max($Hiz, 1), 10)
$sav = [byte]($(if ($Gecici) { 0 } else { 1 }))
$colors = @{ kirmizi=@(255,0,0); yesil=@(0,255,0); mavi=@(0,0,255); beyaz=@(255,255,255); sicakbeyaz=@(255,180,110); sari=@(255,200,0);
             turuncu=@(255,60,0); mor=@(255,0,255); turkuaz=@(0,255,255); pembe=@(255,20,147) }

switch ($Komut.ToLower()) {
    "tani" {
        Write-Host "Cihaz      : $($dev.FriendlyName)  [$($dev.Status)]"
        Write-Host "Yol        : $path"
        Write-Host "Rapor boyu : Feature=$FLen  Output=$OLen  Input=$($caps.InputReportByteLength)  UsagePage=0x$('{0:X4}' -f $caps.UsagePage)"
        if (Ctrl @(0x80)) { $fw = GetCtrl; if ($fw) { Write-Host ("Firmware   : {0}.{1}.{2}.{3}" -f $fw[1], $fw[2], $fw[3], $fw[4]) } }
        if (Ctrl @(0x88)) { $ef = GetCtrl; if ($ef) {
            Write-Host ("Durum ham  : {0}" -f (($ef | % { '{0:X2}' -f $_ }) -join ' '))
            Write-Host ("Kapali mi  : {0}   Efekt=0x{1:X2} Hiz={2} Parlaklik={3} Renk={4} Yon={5} Kayit={6}" -f ($ef[1] -eq 1), $ef[2], $ef[3], $ef[4], $ef[5], $ef[6], $ef[7])
        } }
        $gcu = Get-Process -Name "GCUService" -ErrorAction SilentlyContinue
        if ($gcu) {
            Write-Host ("OEM Servis : GCUService calisiyor (PID $($gcu.Id))")
        }
        $ec = Get-EcSensors
        if ($ec) {
            Write-Host ("Sicaklik   : CPU={0} C   GPU={1} C" -f $ec.CpuTemp, $ec.GpuTemp)
            Write-Host ("Fan Hizi   : CPU Fan={0} RPM (%{1})   GPU Fan={2} RPM (%{3})" -f $ec.CpuFanRpm, $ec.CpuFanPct, $ec.GpuFanRpm, $ec.GpuFanPct)
        }
    }
    "kapat"    {
        $frame = New-Object byte[] 512
        EnterCustomMode 0 $sav
        SendFrame $frame
        [void](Ctrl @(0x08, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        [void](Ctrl @(0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        [void](SyncOemRegistry 1 0 $spd 0 0 0 0 $false)
        Write-Host "[OK] Isik tamamen kapatildi." -ForegroundColor Green
    }
    "parlaklik"{
        # FW 34.3.0.0: Mevcut efekti 0x88 ile oku ve 0x08 0x02 uzerinden parlakligi guncelle
        $curEf = 0x05; $curSpd = $spd; $curCol = 0x08; $curDir = 0x01
        if (Ctrl @(0x88)) {
            $st = GetCtrl
            if ($st -and $st[2] -ne 0) {
                $curEf  = $st[2]
                $curSpd = if ($st[3] -gt 0) { $st[3] } else { $spd }
                $curCol = $st[5]
                $curDir = $st[6]
            }
        }
        [void](Ctrl @(0x08, 0x02, $curEf, $curSpd, $bri, $curCol, $curDir, $sav))
        $oemEf = if ($curEf -eq 0x33) { 1 } else { [int]$curEf }
        [void](SyncOemRegistry $oemEf $bri $curSpd $curDir 255 0 0 ($bri -gt 0))
        Write-Host "[OK] Parlaklik $bri/50 (Efekt=0x$('{0:X2}' -f $curEf))" -ForegroundColor Green
    }
    "renk" {
        $c = $colors[$Arg1.ToLower()]
        if (-not $c -and $Arg1 -match '^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$') {
            $c = @(
                [Math]::Min([Math]::Max([int]$Matches[1], 0), 255),
                [Math]::Min([Math]::Max([int]$Matches[2], 0), 255),
                [Math]::Min([Math]::Max([int]$Matches[3], 0), 255)
            )
        } elseif (-not $c -and $Arg1 -match '^#?([0-9a-fA-F]{6})$') {
            $hex = $Matches[1]
            $c = @(
                [Convert]::ToInt32($hex.Substring(0, 2), 16),
                [Convert]::ToInt32($hex.Substring(2, 2), 16),
                [Convert]::ToInt32($hex.Substring(4, 2), 16)
            )
        }
        if (-not $c) { Write-Host "Renkler: $($colors.Keys -join ', ') veya R,G,B / #RRGGBB"; break }
        SetAllKeys ([byte]$c[0]) ([byte]$c[1]) ([byte]$c[2]) $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 ([byte]$c[0]) ([byte]$c[1]) ([byte]$c[2]) $true)
        Write-Host "[OK] Tum tuslar: $Arg1 (parlaklik $bri/50)" -ForegroundColor Green
    }
    "test" {
        foreach ($n in 'kirmizi','yesil','mavi','beyaz') { $c = $colors[$n]; Write-Host " -> $n"; SetAllKeys ([byte]$c[0]) ([byte]$c[1]) ([byte]$c[2]) $bri $sav; Start-Sleep 2 }
    }
    "dalga"    {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 0 0 0 $true)
        Write-Host "[OK] Dalga (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "nefes"    {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x02, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 2 $bri $spd 1 0 0 0 $true)
        Write-Host "[OK] Nefes (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "aurora"   {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x0E, $spd, $bri, 0x08, 0x00, $sav))
        [void](SyncOemRegistry 14 $bri $spd 0 0 0 0 $true)
        Write-Host "[OK] Aurora (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "orijinal" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x05, $spd, $bri, 0x01, 0x01, $sav))
        [void](SyncOemRegistry 5 $bri $spd 1 0 0 0 $true)
        Write-Host "[OK] Fabrika gokkusagi (rainbow) geri yuklendi (parlaklik $bri/50)." -ForegroundColor Green
    }
    "dikeydalga" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x03, $sav))
        [void](SyncOemRegistry 3 $bri $spd 3 0 0 0 $true)
        Write-Host "[OK] Dikey Dalga (yukaridan asagi) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "neon" {
        # Not: FW 34.3.0.0 uzerinde 0x0F AP-mode oldugundan bozulma yapar;
        # donanimsal 7-slot Neon Synthwave paleti + 0x02 (Nefes/Renk Gecisi) ve 0x03 ile 60 FPS puruzsuz calisir.
        SendPrelude
        NeonPalette
        [void](Ctrl @(0x08, 0x02, 0x02, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 2 $bri $spd 1 255 0 128 $true)
        Write-Host "[OK] Neon Synthwave Renk Gecisi (Pembe-Mor-Turkuaz) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "neondalga" {
        SendPrelude
        NeonPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 255 0 128 $true)
        Write-Host "[OK] Neon Synthwave Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "lav" {
        SendPrelude
        FirePalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 255 60 0 $true)
        Write-Host "[OK] Ates ve Lav Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "kuzey" {
        SendPrelude
        NorthernPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 0 220 180 $true)
        Write-Host "[OK] Kuzey Isiklari Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "kayan" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x09, $spd, $bri, 0x08, 0x00, $sav))
        [void](SyncOemRegistry 9 $bri $spd 0 0 0 0 $true)
        Write-Host "[OK] Kayan Isik / Marquee (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "yagmur" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x0A, $spd, $bri, 0x08, 0x00, $sav))
        [void](SyncOemRegistry 10 $bri $spd 0 0 0 0 $true)
        Write-Host "[OK] Yagmur Damlasi / Raindrop (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "rastgele" {
        # Donanim efekti 0x04 (Random): firmware'de calisir, surekli yazim yok.
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x04, $spd, $bri, 0x08, 0x00, $sav))
        [void](SyncOemRegistry 4 $bri $spd 0 0 0 0 $true)
        Write-Host "[OK] Rastgele / Random (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "tersdalga" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x02, $sav))
        [void](SyncOemRegistry 3 $bri $spd 2 0 0 0 $true)
        Write-Host "[OK] Ters Dalga (sagdan sola) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "yukaridalga" {
        SendPrelude
        DefaultPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x04, $sav))
        [void](SyncOemRegistry 3 $bri $spd 4 0 0 0 $true)
        Write-Host "[OK] Yukselen Dalga (asagidan yukari) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "altin" {
        SendPrelude
        RoyalPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 255 200 0 $true)
        Write-Host "[OK] Altin & Kraliyet Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "zehir" {
        SendPrelude
        ToxicPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 120 255 0 $true)
        Write-Host "[OK] Toksik / Biohazard Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "sakura" {
        SendPrelude
        SakuraPalette
        [void](Ctrl @(0x08, 0x02, 0x03, $spd, $bri, 0x08, 0x01, $sav))
        [void](SyncOemRegistry 3 $bri $spd 1 255 80 160 $true)
        Write-Host "[OK] Sakura / Kiraz Cicegi Dalgasi (Hareketli) (parlaklik $bri/50, hiz $spd)" -ForegroundColor Green
    }
    "oyuncu" {
        SetThemePreset "oyuncu" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 0 0 $true)
        Write-Host "[OK] Ozel Tema: FPS Oyuncu (WASD + Oklar Kirmizi, Yardimcilar Turkuaz)" -ForegroundColor Green
    }
    "moba" {
        SetThemePreset "moba" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 0 240 255 $true)
        Write-Host "[OK] Ozel Tema: MOBA Oyuncu (QWER Turkuaz, DF Altin, 1-7 Yesil)" -ForegroundColor Green
    }
    "siber" {
        SetThemePreset "siber" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 0 128 $true)
        Write-Host "[OK] Ozel Tema: Cyberpunk 2077 (Sari / Pembe / Turkuaz)" -ForegroundColor Green
    }
    "gunbatimi" {
        SetThemePreset "gunbatimi" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 95 0 $true)
        Write-Host "[OK] Ozel Tema: Gunbatimi Gradyan (Kirmizi -> Turuncu -> Mor)" -ForegroundColor Green
    }
    "okyanus" {
        SetThemePreset "okyanus" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 0 200 255 $true)
        Write-Host "[OK] Ozel Tema: Okyanus & Kuzey Isiklari Gradyan" -ForegroundColor Green
    }
    "atesbuz" {
        SetThemePreset "atesbuz" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 60 0 $true)
        Write-Host "[OK] Ozel Tema: Ates ve Buz (Sol Ates / Sag Buz)" -ForegroundColor Green
    }
    "matrix" {
        SetThemePreset "matrix" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 0 255 40 $true)
        Write-Host "[OK] Ozel Tema: Matrix / Kodlayici Modu" -ForegroundColor Green
    }
    "retro" {
        SetThemePreset "retro" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 0 128 $true)
        Write-Host "[OK] Ozel Tema: 80'ler Retro Outrun (6 Renk Satir Kusagi)" -ForegroundColor Green
    }
    "turkbayragi" {
        SetThemePreset "turkbayragi" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 0 0 $true)
        Write-Host "[OK] Ozel Tema: Al-Beyaz (Kirmizi Zemin + Beyaz Ay-Yildiz)" -ForegroundColor Green
    }
    "galaksi" {
        SetThemePreset "galaksi" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 140 0 255 $true)
        Write-Host "[OK] Ozel Tema: Derin Uzay & Galaksi Bulutsusu" -ForegroundColor Green
    }
    "keskin" {
        SetThemePreset "keskin" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 220 235 255 $true)
        Write-Host "[OK] Ozel Tema: Keskin Kontrast (Buz Beyazi + Kirmizi WASD)" -ForegroundColor Green
    }
    "gokkusagisabit" {
        SetThemePreset "gokkusagisabit" $bri $sav
        [void](SyncOemRegistry 1 $bri $spd 1 255 180 0 $true)
        Write-Host "[OK] Ozel Tema: Sabit Gokkusagi Spektrumu" -ForegroundColor Green
    }
    "sistem" {
        $altMod = if ($Arg1) { $Arg1.ToLower() } else { "gosterge" }
        $m = SetSystemMonitorFrame $altMod $bri 0
        Write-Host ("[OK] Sistem ({0}) -> CPU: {1}C (%{2}) | GPU: {3}C | Fan: {4}/{5} RPM | RAM: %{6}" -f $altMod, $m.CpuTemp, $m.Cpu, $m.GpuTemp, $m.CpuFanRpm, $m.GpuFanRpm, $m.Ram) -ForegroundColor Green
    }
    "fan" {
        $fanMod = if ($Arg1) { $Arg1.ToLower() } else { "oto" }
        $fanVal = if ($Arg2) { [int]$Arg2 } else { -1 }
        [void](Set-EcFanMode $fanMod $fanVal)
    }
    "servis-yenile" {
        Restart-OemService
    }
    default    { Write-Host "Komutlar: tani | kapat | parlaklik | renk <ad> | dalga | nefes | aurora | orijinal | tepkisel | rastgele | kayan | yagmur | neon | kivilcim | oyuncu | siber | gunbatimi | okyanus | atesbuz | matrix | servis-yenile" }
}
$h.Close()
