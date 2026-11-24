param(
    [switch]$TestYukle
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

if (-not ("EcSensor" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class EcSensor {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle hDevice, uint dwIoControlCode,
        byte[] lpInBuffer, int nInBufferSize,
        byte[] lpOutBuffer, int nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    private static int ReadByte(SafeFileHandle h, int addr) {
        byte[] inBuf = BitConverter.GetBytes(addr);
        byte[] outBuf = new byte[4];
        uint ret = 0;
        if (!DeviceIoControl(h, 0x9C40A488u, inBuf, 4, outBuf, 1, out ret, IntPtr.Zero))
            return -1;
        return outBuf[0];
    }

    private static bool WriteByte(SafeFileHandle h, int addr, byte val) {
        byte[] inB = new byte[8];
        Buffer.BlockCopy(BitConverter.GetBytes(addr), 0, inB, 0, 4);
        inB[4] = val;
        byte[] outB = new byte[4];
        uint ret = 0;
        return DeviceIoControl(h, 0x9C40A48Cu, inB, 8, outB, 4, out ret, IntPtr.Zero);
    }

    // EC register haritasi (REA olcumu ile DOGRULANDI, OEM Kontrol Merkezi gozlemi):
    //   0x751 = ADDR_MAFAN_CONTROL_BYTE  (fan mod bayragi)
    //        0x00 = Dengeli   | 0x10 = Turbo | 0xA0 = Ofis/sessiz
    //   0x7DA = TURBO_TCC  (Turbo alt modu: 95 = Sessiz Performans, 97 = Ekstrem Performans)
    //   0x75B/0x75C = CPU/GPU duty (EC tarafından hesaplanir; yazım yok sayılır)
    //   0x767 = ADDR_TRIGGER_BYTE -> TUM olcumlerde 0x00; OEM bu bayragi kullanmiyor.
    //          (Eski "0x04 = force-max" varsayimi normal mod gecislerinde gecersiz.)
    private static bool WriteFanRegs(byte fan751, byte tcc7da) {
        using (var h = CreateFile("\\\\.\\ACPIDriver", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            if (!WriteByte(h, 0x751, fan751)) return false;
            if (!WriteByte(h, 0x7DA, tcc7da)) return false;
            return true;
        }
    }

    public static bool SetProfileOfis()    { return WriteFanRegs(0xA0, 95); }
    public static bool SetProfileDengeli() { return WriteFanRegs(0x00, 95); }
    public static bool SetProfileTurboSessiz()  { return WriteFanRegs(0x10, 95); }
    public static bool SetProfileTurboEkstrem() { return WriteFanRegs(0x10, 97); }

    // Mevcut modu 0x751 + 0x7DA'dan oku ve isim döndür.
    public static string ReadProfileName() {
        using (var h = CreateFile("\\\\.\\ACPIDriver", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return "(EC yok)";
            int f = ReadByte(h, 0x751);
            int tcc = ReadByte(h, 0x7DA);
            if (f < 0) return "(okunamadi)";
            if (f == 0xA0) return "Ofis";
            if (f == 0x00) return "Dengeli";
            if (f == 0x10) return (tcc == 97) ? "Turbo / Ekstrem" : "Turbo / Sessiz";
            return ("Bilinmeyen (0x" + f.ToString("X2") + ")");
        }
    }

    private static bool SetFanDuty(byte duty) {
        // Duty yazımı bu makinada EC tarafından yok sayılıyor; yalnızca duty yazarız.
        using (var h = CreateFile("\\\\.\\ACPIDriver", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            WriteByte(h, 0x75B, duty);
            WriteByte(h, 0x75C, duty);
            return true;
        }
    }

    public static bool SetFanBoost(bool enable) {
        // Bu modelde "boost" = Turbo / Ekstrem Performans.
        return enable ? SetProfileTurboEkstrem() : SetProfileDengeli();
    }

    public static bool SetFanAuto() {
        return SetProfileDengeli();
    }

    // Yazim öncesi 0x751'in ham değerini oku; geri yükleme için saklanir.
    public static int SnapshotFanMode() {
        return ReadFanMode();
    }

    public static bool SetFanMode(int mode) {
        // 0=Dengeli, 1=Turbo, 2=Ofis
        if (mode == 1) return SetProfileTurboSessiz();
        if (mode == 2) return SetProfileOfis();
        return SetProfileDengeli();
    }

    public static bool SetFanManualSpeed(int percent) {
        if (percent < 20) percent = 20;
        if (percent > 100) percent = 100;
        return SetFanDuty((byte)(percent * 2));
    }

    public static int ReadFanMode() {
        using (var h = CreateFile("\\\\.\\ACPIDriver", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return -1;
            return ReadByte(h, 0x751);
        }
    }

    public static int[] ReadAll() {
        using (var h = CreateFile("\\\\.\\ACPIDriver", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return null;
            int cpuTemp = ReadByte(h, 0x43E);
            int gpuTemp = ReadByte(h, 0x46A);
            if (gpuTemp <= 0 || gpuTemp >= 120) {
                int g2 = ReadByte(h, 0x44F);
                if (g2 > 0 && g2 < 120) gpuTemp = g2;
            }
            int f1Hi = ReadByte(h, 0x464);
            int f1Lo = ReadByte(h, 0x465);
            int f2Hi = ReadByte(h, 0x46C);
            int f2Lo = ReadByte(h, 0x46B);
            int d1 = ReadByte(h, 0x75B);
            int d2 = ReadByte(h, 0x75C);
            int cpuRpm = (f1Hi >= 0 && f1Lo >= 0) ? ((f1Hi << 8) | f1Lo) : -1;
            int gpuRpm = (f2Hi >= 0 && f2Lo >= 0) ? ((f2Hi << 8) | f2Lo) : -1;
            int cpuDuty = (d1 >= 0 && d1 <= 200) ? (int)Math.Round(d1 / 2.0) : -1;
            int gpuDuty = (d2 >= 0 && d2 <= 200) ? (int)Math.Round(d2 / 2.0) : -1;
            int fanMode = ReadByte(h, 0x751);
            return new int[] { cpuTemp, gpuTemp, cpuRpm, gpuRpm, cpuDuty, gpuDuty, fanMode };
        }
    }
}
"@
}

$IteScript = Join-Path $PSScriptRoot "ite.ps1"
if (-not (Test-Path $IteScript)) {
    [System.Windows.MessageBox]::Show("ite.ps1 bulunamadı: $IteScript", "Hata", "OK", "Error") | Out-Null
    exit 1
}

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ITE 8291 RGB Klavye Kontrol Paneli"
        Width="1380"
        Height="720"
        MinWidth="1100"
        MinHeight="620"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        Background="#12141C"
        Foreground="#F1F5F9"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1E2230"/>
            <Setter Property="Foreground" Value="#F1F5F9"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#CBD5E1"/>
            <Setter Property="Margin" Value="0,4,18,4"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="1.25*"/>
            <ColumnDefinition Width="1.25*"/>
            <ColumnDefinition Width="1.15*"/>
        </Grid.ColumnDefinitions>

        <!-- ===== SOL SUTUN ===== -->
        <ScrollViewer Grid.Row="0" Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,6,0">
        <StackPanel>

        <!-- Ust Durum Karti -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="ITE 8291 RGB Klavye Kontrolc&#x00FC;s&#x00FC; (048D:600B)" FontSize="15" FontWeight="Bold" Foreground="#F8FAFC" TextWrapping="Wrap"/>
                <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="BtnAdmin" Content="Y&#x00F6;netici" Background="#B45309" BorderBrush="#F59E0B" Padding="8,6" ToolTip="Paneli Y&#x00F6;netici olarak yeniden ba&#x015F;lat&#x0131;r"/>
                    <Button x:Name="BtnTani" Content="Durumu Yenile" Background="#2563EB" BorderBrush="#3B82F6" Padding="8,6"/>
                    <Button x:Name="BtnKapat" Content="I&#x015F;&#x0131;&#x011F;&#x0131; Kapat" Background="#991B1B" BorderBrush="#DC2626" Padding="8,6"/>
                </StackPanel>
                <TextBlock x:Name="TxtCihazDurum" Text="Durum okunuyor..." FontSize="12" Foreground="#94A3B8" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <!-- Parlaklik ve Hiz Ayarlari -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <StackPanel>
                <Grid Margin="0,0,0,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="135"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="60"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Parlakl&#x0131;k (0 - 50):" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    <Slider x:Name="SldParlaklik" Grid.Column="1" Minimum="0" Maximum="50" Value="50" IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="TxtParlaklik" Grid.Column="2" Text="50 / 50" VerticalAlignment="Center" HorizontalAlignment="Right" FontWeight="Bold" Foreground="#38BDF8"/>
                    <Button x:Name="BtnParlaklikUygula" Grid.Column="3" Content="Uygula" Padding="12,5" Margin="10,0,0,0"/>
                </Grid>

                <!-- OEM Parlaklik Kademeleri -->
                <StackPanel Orientation="Horizontal" Margin="135,0,0,8">
                    <TextBlock Text="Kademeler:" Foreground="#94A3B8" VerticalAlignment="Center" Margin="0,0,6,0" FontSize="11"/>
                    <Button x:Name="BtnBri0" Content="0" Padding="6,3" FontSize="11" Margin="2" ToolTip="Parlaklık 0"/>
                    <Button x:Name="BtnBri8" Content="8" Padding="6,3" FontSize="11" Margin="2" ToolTip="Düşük (8)"/>
                    <Button x:Name="BtnBri22" Content="22" Padding="6,3" FontSize="11" Margin="2" ToolTip="Orta (22)"/>
                    <Button x:Name="BtnBri36" Content="36" Padding="6,3" FontSize="11" Margin="2" ToolTip="Yüksek (36)"/>
                    <Button x:Name="BtnBri50" Content="50" Padding="6,3" FontSize="11" Margin="2" ToolTip="Maks (50)"/>
                </StackPanel>

                <Grid Margin="0,2,0,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="135"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="115"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Efekt H&#x0131;z&#x0131; (1 - 10):" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    <Slider x:Name="SldHiz" Grid.Column="1" Minimum="1" Maximum="10" Value="5" IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="TxtHiz" Grid.Column="2" Text="5 (1=H&#x0131;zl&#x0131;)" VerticalAlignment="Center" HorizontalAlignment="Right" FontWeight="Bold" Foreground="#A78BFA"/>
                </Grid>

                <WrapPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <CheckBox x:Name="ChkKaydet" Content="Kal&#x0131;c&#x0131; Kaydet (NVRAM + OEM Kay&#x0131;t Defteri)" IsChecked="True"/>
                    <CheckBox x:Name="ChkStatikMod" Content="Donan&#x0131;msal Statik Mod (-StatikMod)" IsChecked="False"/>
                    <CheckBox x:Name="ChkServisYenile" Content="GCU Servisini Otomatik Yenile" IsChecked="False"/>
                </WrapPanel>
            </StackPanel>
        </Border>

        <!-- Hazir Renkler -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="H&#x0131;zl&#x0131; Tek Renk Se&#x00E7;imi (T&#x00FC;m Tu&#x015F;lar)" FontWeight="Bold" Margin="0,0,0,6"/>
                <UniformGrid Rows="2" Columns="5">
                    <Button x:Name="BtnRenkKirmizi" Height="32" Content="K&#x0131;rm&#x0131;z&#x0131;" FontSize="11.5" Background="#B91C1C" BorderBrush="#EF4444"/>
                    <Button x:Name="BtnRenkYesil" Height="32" Content="Ye&#x015F;il" FontSize="11.5" Background="#15803D" BorderBrush="#22C55E"/>
                    <Button x:Name="BtnRenkMavi" Height="32" Content="Mavi" FontSize="11.5" Background="#1D4ED8" BorderBrush="#3B82F6"/>
                    <Button x:Name="BtnRenkBeyaz" Height="32" Content="Beyaz" FontSize="11.5" Background="#E2E8F0" Foreground="#0F172A" BorderBrush="#FFFFFF"/>
                    <Button x:Name="BtnRenkSicakBeyaz" Height="32" Content="S&#x0131;cak" FontSize="11" Background="#FDE68A" Foreground="#0F172A" BorderBrush="#F59E0B" Padding="2,2" ToolTip="Sıcak Beyaz"/>
                    <Button x:Name="BtnRenkSari" Height="32" Content="Sar&#x0131;" FontSize="11.5" Background="#CA8A04" BorderBrush="#EAB308"/>
                    <Button x:Name="BtnRenkTuruncu" Height="32" Content="Turuncu" FontSize="11.5" Background="#C2410C" BorderBrush="#F97316"/>
                    <Button x:Name="BtnRenkMor" Height="32" Content="Mor" FontSize="11.5" Background="#7E22CE" BorderBrush="#A855F7"/>
                    <Button x:Name="BtnRenkTurkuaz" Height="32" Content="Turkuaz" FontSize="11.5" Background="#0E7490" BorderBrush="#06B6D4"/>
                    <Button x:Name="BtnRenkPembe" Height="32" Content="Pembe" FontSize="11.5" Background="#BE185D" BorderBrush="#EC4899"/>
                </UniformGrid>
            </StackPanel>
        </Border>

        <!-- Ozel RGB Secici -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,16,0">
                    <TextBlock Text="&#x00D6;zel RGB Renk Olu&#x015F;turucu" FontWeight="Bold" Margin="0,0,0,6"/>
                    <Grid Margin="0,3">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="28"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="38"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="R:" Foreground="#F87171" FontWeight="Bold" VerticalAlignment="Center"/>
                        <Slider x:Name="SldR" Grid.Column="1" Minimum="0" Maximum="255" Value="255" IsSnapToTickEnabled="True" TickFrequency="1"/>
                        <TextBlock x:Name="TxtR" Grid.Column="2" Text="255" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                    <Grid Margin="0,3">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="28"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="38"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="G:" Foreground="#4ADE80" FontWeight="Bold" VerticalAlignment="Center"/>
                        <Slider x:Name="SldG" Grid.Column="1" Minimum="0" Maximum="255" Value="0" IsSnapToTickEnabled="True" TickFrequency="1"/>
                        <TextBlock x:Name="TxtG" Grid.Column="2" Text="0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                    <Grid Margin="0,3">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="28"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="38"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="B:" Foreground="#60A5FA" FontWeight="Bold" VerticalAlignment="Center"/>
                        <Slider x:Name="SldB" Grid.Column="1" Minimum="0" Maximum="255" Value="128" IsSnapToTickEnabled="True" TickFrequency="1"/>
                        <TextBlock x:Name="TxtB" Grid.Column="2" Text="128" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Center">
                    <Border x:Name="BrdOnizleme" Width="120" Height="36" CornerRadius="6" Background="#FF0080" BorderBrush="#475569" BorderThickness="1" Margin="0,0,0,6">
                        <TextBlock x:Name="TxtHex" Text="#FF0080" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="Bold" Foreground="#FFFFFF"/>
                    </Border>
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnRenkSecici" Content="Palet..." Padding="10,6"/>
                        <Button x:Name="BtnOzelRenkUygula" Content="&#x00D6;zel Rengi Uygula" Background="#0284C7" BorderBrush="#38BDF8" Padding="12,6"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
        </Border>

        </StackPanel>
        </ScrollViewer>

        <!-- ===== ORTA SUTUN ===== -->
        <ScrollViewer Grid.Row="0" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,6,0">
        <StackPanel>

        <!-- Donanim Efektleri -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="Donan&#x0131;m Efektleri (ITE 8291 Hareketli Modlar &amp; &#x00D6;zel Paletli Dalgalar)" FontWeight="Bold" Margin="0,0,0,6"/>
                <UniformGrid Rows="5" Columns="4">
                    <Button x:Name="BtnEfektOrijinal" Height="32" Content="G&#x00F6;kku&#x015F;a&#x011F;&#x0131;" FontSize="11.5" Background="#312E81" BorderBrush="#6366F1" ToolTip="Orijinal G&#x00F6;kku&#x015F;a&#x011F;&#x0131;"/>
                    <Button x:Name="BtnEfektAurora" Height="32" Content="Aurora" FontSize="11.5" Background="#065F46" BorderBrush="#10B981"/>
                    <Button x:Name="BtnEfektDalga" Height="32" Content="Dalga (Sa&#x011F;a)" FontSize="11.5" Background="#1E3A8A" BorderBrush="#3B82F6"/>
                    <Button x:Name="BtnEfektTersDalga" Height="32" Content="Ters Dalga" FontSize="11.5" Background="#1D4ED8" BorderBrush="#60A5FA"/>
                    <Button x:Name="BtnEfektDikeyDalga" Height="32" Content="Dikey Dalga" FontSize="11.5" Background="#1E40AF" BorderBrush="#38BDF8"/>
                    <Button x:Name="BtnEfektYukariDalga" Height="32" Content="Y&#x00FC;kselen Dalga" FontSize="11.5" Background="#0369A1" BorderBrush="#7DD3FC"/>
                    <Button x:Name="BtnEfektNefes" Height="32" Content="Nefes" FontSize="11.5" Background="#581C87" BorderBrush="#A855F7"/>
                    <Button x:Name="BtnEfektNeon" Height="32" Content="Neon Ge&#x00E7;i&#x015F;" FontSize="11.5" Background="#701A75" BorderBrush="#D946EF"/>
                    <Button x:Name="BtnEfektNeonDalga" Height="32" Content="Neon Dalga" FontSize="11.5" Background="#831843" BorderBrush="#F472B6"/>
                    <Button x:Name="BtnEfektLav" Height="32" Content="Lav Dalgas&#x0131;" FontSize="11.5" Background="#7C2D12" BorderBrush="#F97316"/>
                    <Button x:Name="BtnEfektKuzey" Height="32" Content="Kuzey I&#x015F;&#x0131;klar&#x0131;" FontSize="11.5" Background="#0C4A6E" BorderBrush="#38BDF8"/>
                    <Button x:Name="BtnEfektAltin" Height="32" Content="Alt&#x0131;n &amp; Kraliyet" FontSize="11.5" Background="#78350F" BorderBrush="#FBBF24"/>
                    <Button x:Name="BtnEfektZehir" Height="32" Content="Toksik / Biohazard" FontSize="11.5" Background="#365314" BorderBrush="#A3E635"/>
                    <Button x:Name="BtnEfektSakura" Height="32" Content="Sakura &#x00C7;i&#x00E7;e&#x011F;i" FontSize="11.5" Background="#9D174D" BorderBrush="#F9A8D4"/>
                    <Button x:Name="BtnEfektYagmur" Height="32" Content="Ya&#x011F;mur Damlas&#x0131;" FontSize="11.5" Background="#1E293B" BorderBrush="#64748B"/>
                    <Button x:Name="BtnEfektBolgeDalga" Height="32" Content="4 B&#x00F6;lge Z&#x0131;t Dalga" FontSize="11.5" Background="#1E3A8A" BorderBrush="#22D3EE" ToolTip="Klavyeyi 4 b&#x00F6;lgeye b&#x00F6;ler, rastgele renklerle a&#x015F;a&#x011F;&#x0131;/yukar&#x0131; akan animasyon. Tekrar bas: durdur."/>
                </UniformGrid>
            </StackPanel>
        </Border>

        <!-- Ozel Per-Key Temalar (Kontrol Merkezinde Olmayan) -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="&#x00D6;zel Tu&#x015F; &amp; Gradyan Temalar&#x0131; (Kontrol Merkezi'nde Olmayan Per-Key Modlar)" FontWeight="Bold" Margin="0,0,0,6"/>
                <UniformGrid Rows="4" Columns="3">
                    <Button x:Name="BtnTemaOyuncu" Height="32" Content="FPS Oyuncu (WASD)" FontSize="11.5" Background="#881337" BorderBrush="#F43F5E"/>
                    <Button x:Name="BtnTemaMoba" Height="32" Content="MOBA (QWER)" FontSize="11.5" Background="#0F766E" BorderBrush="#2DD4BF"/>
                    <Button x:Name="BtnTemaKeskin" Height="32" Content="Keskin (Beyaz/K&#x0131;z&#x0131;l)" FontSize="11.5" Background="#334155" BorderBrush="#F87171"/>
                    <Button x:Name="BtnTemaTurkBayragi" Height="32" Content="Al-Beyaz" FontSize="11.5" Background="#B91C1C" BorderBrush="#FFFFFF"/>
                    <Button x:Name="BtnTemaSiber" Height="32" Content="Cyberpunk 2077" FontSize="11.5" Background="#6B21A8" BorderBrush="#FACC15"/>
                    <Button x:Name="BtnTemaRetro" Height="32" Content="80'ler Retro" FontSize="11.5" Background="#4C1D95" BorderBrush="#F472B6"/>
                    <Button x:Name="BtnTemaGalaksi" Height="32" Content="Derin Uzay" FontSize="11.5" Background="#311042" BorderBrush="#C084FC"/>
                    <Button x:Name="BtnTemaMatrix" Height="32" Content="Matrix" FontSize="11.5" Background="#14532D" BorderBrush="#4ADE80"/>
                    <Button x:Name="BtnTemaGunbatimi" Height="32" Content="G&#x00FC;nbat&#x0131;m&#x0131;" FontSize="11.5" Background="#9A3412" BorderBrush="#FB923C"/>
                    <Button x:Name="BtnTemaOkyanus" Height="32" Content="Okyanus" FontSize="11.5" Background="#115E59" BorderBrush="#2DD4BF"/>
                    <Button x:Name="BtnTemaAtesBuz" Height="32" Content="Ate&#x015F; ve Buz" FontSize="11.5" Background="#1E3A8A" BorderBrush="#F87171"/>
                    <Button x:Name="BtnTemaGokkusagiSabit" Height="32" Content="Sabit G&#x00F6;kku&#x015F;a&#x011F;&#x0131;" FontSize="11.5" Background="#3730A3" BorderBrush="#FBBF24"/>
                </UniformGrid>
            </StackPanel>
        </Border>

        </StackPanel>
        </ScrollViewer>

        <!-- ===== SAG SUTUN ===== -->
        <ScrollViewer Grid.Row="0" Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>

        <!-- Anlik Sistem Gostergesi ve Canli EC Sensorleri -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10">
            <StackPanel>
                <Grid Margin="0,0,0,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Canl&#x0131; EC Sens&#x00F6;rleri (CPU / GPU S&#x0131;cakl&#x0131;k &amp; Fan H&#x0131;z&#x0131;)" FontWeight="Bold" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtSistemMetrik" Grid.Column="1" Text="EC Sensörleri Aktif" Foreground="#38BDF8" FontSize="11.5" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold"/>
                </Grid>

                <!-- GERCEK MOD (EC'den okunur — donanim mod tusunu da yakalar) -->
                <Border Background="#0B1220" BorderBrush="#1E293B" BorderThickness="1" CornerRadius="6" Padding="10,7" Margin="0,0,0,8">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Ger&#x00E7;ek Fan Modu (EC)" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtGercekMod" Grid.Column="1" Text="--" FontSize="15" FontWeight="Bold" Foreground="#2DD4BF" VerticalAlignment="Center" Margin="12,0,0,0"/>
                        <TextBlock x:Name="TxtOemFark" Grid.Column="2" Text="" FontSize="10.5" Foreground="#F59E0B" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    </Grid>
                </Border>

                <!-- 4 Canli Sensor Karti (Sifir HID Trafigi - Dogrudan EC Okuma) -->
                <UniformGrid Rows="1" Columns="4" Margin="0,0,0,8">
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="0,0,4,0">
                        <StackPanel>
                            <TextBlock Text="CPU SICAKLI&#x011E;I" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcCpuTemp" Text="-- &#x00B0;C" FontSize="15" FontWeight="Bold" Foreground="#38BDF8" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,4,0">
                        <StackPanel>
                            <TextBlock Text="GPU SICAKLI&#x011E;I" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcGpuTemp" Text="-- &#x00B0;C" FontSize="15" FontWeight="Bold" Foreground="#4ADE80" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,4,0">
                        <StackPanel>
                            <TextBlock Text="CPU FAN HIZI" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcCpuFan" Text="-- RPM" FontSize="12" FontWeight="Bold" Foreground="#A78BFA" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,0,0">
                        <StackPanel>
                            <TextBlock Text="GPU FAN HIZI" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcGpuFan" Text="-- RPM" FontSize="12" FontWeight="Bold" Foreground="#F472B6" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                </UniformGrid>

                <!-- Guc Cekimi (Watt) + OEM Kontrol Durumu -->
                <UniformGrid Rows="1" Columns="4" Margin="0,0,0,8">
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="0,0,4,0">
                        <StackPanel>
                            <TextBlock Text="GPU G&#x00DC;&#x00C7;&#x00DC; (W)" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcGpuWatt" Text="-- W" FontSize="15" FontWeight="Bold" Foreground="#FBBF24" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,4,0">
                        <StackPanel>
                            <TextBlock Text="CPU G&#x00DC;&#x00C7;&#x00DC; (W)" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtEcCpuWatt" Text="-- W" FontSize="15" FontWeight="Bold" Foreground="#60A5FA" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,4,0">
                        <StackPanel>
                            <TextBlock Text="OEM KONTROL" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtOemKontrol" Text="--" FontSize="11" FontWeight="Bold" Foreground="#F59E0B" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#121622" BorderBrush="#2A344B" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="4,0,0,0">
                        <StackPanel>
                            <TextBlock Text="AKT&#x0130;F MOD" FontSize="10.5" Foreground="#94A3B8" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtAktifMod" Text="--" FontSize="11" FontWeight="Bold" Foreground="#2DD4BF" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                </UniformGrid>

                <UniformGrid Rows="1" Columns="2">
                    <Button x:Name="BtnMonGosterge" Height="34" Content="Anl&#x0131;k CPU (F1-F12) &amp; RAM (1-0) Bar&#x0131;" Background="#0F766E" BorderBrush="#2DD4BF"/>
                    <Button x:Name="BtnMonPil" Height="34" Content="Anl&#x0131;k Pil &amp; &#x015E;arj Doluluk Bar&#x0131;" Background="#1E3A8A" BorderBrush="#3B82F6"/>
                </UniformGrid>
            </StackPanel>
        </Border>

        <!-- Donanimsal Fan Hizi ve Mod Kontrolu (EC ACPIDriver) -->
        <Border Background="#1A1E2B" BorderBrush="#2E364F" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10">
            <StackPanel>
                <Grid Margin="0,0,0,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Donan&#x0131;m Fan Kontrol&#x00FC; (EC do&#x011F;rudan)" FontWeight="Bold" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtFanModDurum" Grid.Column="1" Text="Mod: --" Foreground="#38BDF8" FontSize="11.5" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold"/>
                </Grid>

                <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="#94A3B8" Margin="0,0,0,8"
                           Text="REA ölçümüyle doğrulanmış mod eşlemesi (0x751 + 0x7DA TCC). OEM servisi açıksa bu yazımlar ezilebilir. Duty (0x75B/0x75C) EC tarafından hesaplanır, yazım yok sayılır."/>

                <!-- Fan Mod Butonlari (REA olcumu ile DOGRULANDI) -->
                <UniformGrid Rows="1" Columns="4" Margin="0,0,0,8">
                    <Button x:Name="BtnProfilOfis"        Height="34" Content="Ofis"             Background="#166534" BorderBrush="#22C55E" FontSize="11.5" ToolTip="0x751=0xA0, TCC=95 — sessiz, TGP kapali"/>
                    <Button x:Name="BtnProfilDengeli"    Height="34" Content="Dengeli"          Background="#0F766E" BorderBrush="#2DD4BF" FontSize="11.5" ToolTip="0x751=0x00, TCC=95 — EC normal eğrisi"/>
                    <Button x:Name="BtnProfilTurboSessiz" Height="34" Content="Turbo / Sessiz"   Background="#7C3AED" BorderBrush="#A78BFA" FontSize="11.5" ToolTip="0x751=0x10, TCC=95 — Turbo sessiz performans"/>
                    <Button x:Name="BtnProfilTurboEkstrem" Height="34" Content="Turbo / Ekstrem"  Background="#B45309" BorderBrush="#F59E0B" FontSize="11.5" ToolTip="0x751=0x10, TCC=97 — Turbo ekstrem performans"/>
                </UniformGrid>

                <!-- Manuel Fan Yuzdesi Slider -->
                <Grid Margin="0,2,0,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="135"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="55"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Manuel Fan (%20 - %100):" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    <Slider x:Name="SldFanManuel" Grid.Column="1" Minimum="20" Maximum="100" Value="60" IsSnapToTickEnabled="True" TickFrequency="5" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="TxtFanManuel" Grid.Column="2" Text="%60" VerticalAlignment="Center" HorizontalAlignment="Right" FontWeight="Bold" Foreground="#38BDF8"/>
                    <Button x:Name="BtnFanManuelUygula" Grid.Column="3" Content="Uygula" Padding="12,4" Margin="10,0,0,0"/>
                </Grid>

                <UniformGrid Rows="1" Columns="2" Margin="0,4,0,0">
                    <Button x:Name="BtnAcOemCenter" Height="36" Content="Kontrol Merkezi'ni A&#x00E7; (Fan / G&#x00FC;&#x00E7; Modu)" Background="#1D4ED8" BorderBrush="#60A5FA" ToolTip="OEM fan/güç modunu değiştirmek için resmi Kontrol Merkezi uygulamasını açar"/>
                    <Button x:Name="BtnOemDurumYenile" Height="36" Content="OEM Durumunu Oku" Background="#0F766E" BorderBrush="#2DD4BF" ToolTip="EC'nin gerçek fan modu durumunu yeniden okur"/>
                </UniformGrid>
            </StackPanel>
        </Border>

        </StackPanel>
        </ScrollViewer>

        <!-- Alt Bilgi Cubugu -->
        <Border Grid.Row="1" Grid.ColumnSpan="3" Background="#0F172A" BorderBrush="#1E293B" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,10,0,0">
            <TextBlock x:Name="TxtLog" Text="Haz&#x0131;r." Foreground="#38BDF8" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
        </Border>
    </Grid>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [System.Windows.Markup.XamlReader]::Load($Reader)

# Pencereyi ekranın çalışma alanına sığdır (kapatma düğmesi her zaman görünür kalsın)
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxW = [Math]::Max(900, [int]($wa.Width * 0.95))
    $maxH = [Math]::Max(600, [int]($wa.Height * 0.95))
    $Window.MaxWidth = $maxW
    $Window.MaxHeight = $maxH
    if ($Window.Width -gt $maxW) { $Window.Width = $maxW }
    if ($Window.Height -gt $maxH) { $Window.Height = $maxH }
    $Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
} catch {}

function Get-Control([string]$Name) {
    return $Window.FindName($Name)
}

function U([string]$Escaped) {
    return [regex]::Unescape($Escaped)
}

$TxtCihazDurum      = Get-Control "TxtCihazDurum"
$script:RgbAvailable = $null
$script:BolgeDalgaProc = $null
$script:BolgePidFile = Join-Path $env:TEMP 'rea_bolge_dalga.pid'
$TxtLog             = Get-Control "TxtLog"
$SldParlaklik       = Get-Control "SldParlaklik"
$TxtParlaklik       = Get-Control "TxtParlaklik"
$SldHiz             = Get-Control "SldHiz"
$TxtHiz             = Get-Control "TxtHiz"
$ChkKaydet          = Get-Control "ChkKaydet"
$ChkStatikMod       = Get-Control "ChkStatikMod"
$ChkServisYenile    = Get-Control "ChkServisYenile"
$SldR               = Get-Control "SldR"
$SldG               = Get-Control "SldG"
$SldB               = Get-Control "SldB"
$TxtR               = Get-Control "TxtR"
$TxtG               = Get-Control "TxtG"
$TxtB               = Get-Control "TxtB"
$BrdOnizleme        = Get-Control "BrdOnizleme"
$TxtHex             = Get-Control "TxtHex"
$TxtSistemMetrik    = Get-Control "TxtSistemMetrik"
$TxtEcCpuTemp       = Get-Control "TxtEcCpuTemp"
$TxtEcGpuTemp       = Get-Control "TxtEcGpuTemp"
$TxtEcCpuFan        = Get-Control "TxtEcCpuFan"
$TxtEcGpuFan        = Get-Control "TxtEcGpuFan"
$TxtFanModDurum     = Get-Control "TxtFanModDurum"
$TxtGercekMod       = Get-Control "TxtGercekMod"
$TxtOemFark         = Get-Control "TxtOemFark"
$SldFanManuel       = Get-Control "SldFanManuel"
$TxtFanManuel       = Get-Control "TxtFanManuel"
$TxtEcGpuWatt       = Get-Control "TxtEcGpuWatt"
$TxtEcCpuWatt       = Get-Control "TxtEcCpuWatt"
$TxtOemKontrol      = Get-Control "TxtOemKontrol"
$TxtAktifMod        = Get-Control "TxtAktifMod"

function Get-GpuWatt {
    # nvidia-smi güvenli okuma; bulunamazsa veya GPU yoksa boş döner
    try {
        $smi = Get-Command nvidia-smi -ErrorAction Stop
        $out = & $smi.Source --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
        if ($out -match '^\s*([0-9]+(\.[0-9]+)?)') {
            return [double]$Matches[1]
        }
    } catch {}
    return $null
}

function Get-CpuWatt {
    # CPU watt doğrudan okunamıyor (EC VRM register adresi çözülmedi).
    # RyzenAdj/HWiNFO yoksa null döner; panel "--" gösterir.
    return $null
}

function Get-OemState {
    # OEM Kontrol Merkezi kaldırıldı; bu makinada EC fan modunu yöneten resmi
    # uygulama/servis yok. Durumu yalnızca süreç varlığından raporla, dosya okumaya.
    $result = [ordered]@{}
    $gcu = Get-Process -Name 'GCUService' -ErrorAction SilentlyContinue
    $bridge = Get-Process -Name 'GCUBridge' -ErrorAction SilentlyContinue
    $result.Running = [bool]($gcu -and $bridge)
    $result.ActiveMode = 'YOK'
    $result.FanBoost = $false
    $result.OperatingMode = -1
    return $result
}

$script:MainOptionPath = $null

function Get-FanBoostEnabled {
    # OEM kaldırıldığı için dosya kaynağı yok; EC'nin 0x751'inden oku.
    try {
        $m = [EcSensor]::ReadFanMode()
        return ($m -eq 64 -or $m -eq 1)
    } catch { return $null }
}

function Update-FanBoostButton {
    # Guncel fan profilini EC'den (0x751 + 0x7DA) oku ve etiketi guncelle.
    $lbl = Get-Control 'TxtFanModDurum'
    if (-not $lbl) { return }
    $name = [EcSensor]::ReadProfileName()
    $col = switch -Regex ($name) {
        '^Ofis'             { @(34,197,94) }
        '^Dengeli'          { @(45,212,191) }
        '^Turbo / Sessiz'   { @(167,139,250) }
        '^Turbo / Ekstrem'  { @(245,158,11) }
        default             { @(148,163,184) }
    }
    $lbl.Text = (U "Mod: $name")
    $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($col[0], $col[1], $col[2]))
}

function Update-EcSensors {
    try {
        $vals = [EcSensor]::ReadAll()
        if ($null -eq $vals -or $vals.Length -lt 6) { return }
        $cTemp = $vals[0]
        $gTemp = $vals[1]
        $cRpm  = $vals[2]
        $gRpm  = $vals[3]
        $cDuty = $vals[4]
        $gDuty = $vals[5]

        if ($cTemp -gt 0 -and $cTemp -lt 120) {
            $TxtEcCpuTemp.Text = (U "$cTemp \u00B0C")
            $TxtEcCpuTemp.Foreground = if ($cTemp -ge 80) {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(248, 113, 113))
            } elseif ($cTemp -ge 65) {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(251, 191, 36))
            } else {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(56, 189, 248))
            }
        }
        if ($gTemp -gt 0 -and $gTemp -lt 120) {
            $TxtEcGpuTemp.Text = (U "$gTemp \u00B0C")
            $TxtEcGpuTemp.Foreground = if ($gTemp -ge 80) {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(248, 113, 113))
            } elseif ($gTemp -ge 65) {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(251, 191, 36))
            } else {
                New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(74, 222, 128))
            }
        }
        if ($cRpm -ge 0) {
            $TxtEcCpuFan.Text = if ($cDuty -ge 0) { "$cRpm RPM %$cDuty" } else { "$cRpm RPM" }
        }
        if ($gRpm -ge 0) {
            $TxtEcGpuFan.Text = if ($gDuty -ge 0) { "$gRpm RPM %$gDuty" } else { "$gRpm RPM" }
        }

        # GPU watt (nvidia-smi)
        $gW = Get-GpuWatt
        if ($null -ne $gW) {
            $TxtEcGpuWatt.Text = ("{0:N1} W" -f $gW)
        }

        # OEM durumu
        $oem = Get-OemState
        if ($oem.Running) {
            $TxtOemKontrol.Text = (U "AKT\u0130F")
            $TxtOemKontrol.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(245, 158, 11))
        } else {
            $TxtOemKontrol.Text = (U "YOK")
            $TxtOemKontrol.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(148, 163, 184))
        }
        $TxtAktifMod.Text = $oem.ActiveMode

        # GERCEK MOD: EC'den canli oku (donanim mod tusunu da yakalar).
        $gercek = [EcSensor]::ReadProfileName()
        if ($TxtGercekMod) {
            $TxtGercekMod.Text = $gercek
            $gc = switch -Regex ($gercek) {
                '^Ofis'            { @(34,197,94) }
                '^Dengeli'         { @(45,212,191) }
                '^Turbo / Sessiz'  { @(167,139,250) }
                '^Turbo / Ekstrem' { @(245,158,11) }
                default            { @(148,163,184) }
            }
            $TxtGercekMod.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($gc[0], $gc[1], $gc[2]))
        }
    } catch {}
}

$EcTimer = New-Object System.Windows.Threading.DispatcherTimer
$EcTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$EcTimer.Add_Tick({ Update-EcSensors })
$EcTimer.Start()
$Window.Add_Closed({
    $EcTimer.Stop(); $RestoreTimer.Stop()
    # Animasyon bilerek durdurulmaz: panel kapansa da kullanici degistirene kadar doner.
})

$RestoreTimer = New-Object System.Windows.Threading.DispatcherTimer
$RestoreTimer.Interval = [TimeSpan]::FromMilliseconds(3500)
$script:SonEfektKomutu = "dalga"
$script:SonEfektArg = ""

$RestoreTimer.Add_Tick({
    $RestoreTimer.Stop()
    if ($script:SonEfektKomutu) {
        [void](Invoke-IteCommand $script:SonEfektKomutu $script:SonEfektArg)
        Update-DeviceStatus
    }
})

function Show-SystemSnapshot([string]$Mod) {
    if ([int]$SldParlaklik.Value -eq 0) { $SldParlaklik.Value = 50 }
    $out = Invoke-IteCommand "sistem" $Mod
    if ($out -match '->\s*(.+)$') {
        $TxtSistemMetrik.Text = ($Matches[1].Trim() + (U "  (3.5 sn sonra efekte d\u00F6ner)"))
    }
    $RestoreTimer.Stop()
    $RestoreTimer.Start()
}

$EfektAdlari = @{
    0x01 = (U "Statik Tek Renk (0x01)")
    0x02 = (U "Nefes (0x02)")
    0x03 = (U "Dalga (0x03)")
    0x04 = (U "Tepkisel / Reactive (0x04)")
    0x05 = (U "G\u00F6kku\u015Fa\u011F\u0131 / Orijinal (0x05)")
    0x06 = (U "Dalgalanma / Ripple (0x06)")
    0x09 = (U "Kayan I\u015F\u0131k / Marquee (0x09)")
    0x0A = (U "Ya\u011Fmur Damlas\u0131 / Raindrop (0x0A)")
    0x0E = (U "Aurora (0x0E)")
    0x0F = (U "Neon Ge\u00E7i\u015F (0x0F)")
    0x11 = (U "K\u0131v\u0131lc\u0131m / Spark (0x11)")
    0x33 = (U "\u00D6zel Renk / Per-Key (0x33)")
}

function Stop-BolgeAnimasyon {
    # Calisan animasyon surecini (varsa) durdur. PID dosyadan da okunur,
    # boylece panel yeniden acildiginda eski animasyonu da durdurabiliriz.
    if ($script:BolgeDalgaProc) {
        try { if (-not $script:BolgeDalgaProc.HasExited) { Stop-Process -Id $script:BolgeDalgaProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    $script:BolgeDalgaProc = $null
    try {
        if (Test-Path $script:BolgePidFile) {
            $oldPid = [int](Get-Content -Raw $script:BolgePidFile).Trim()
            $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'powershell') { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
            Remove-Item $script:BolgePidFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    $b = Get-Control 'BtnEfektBolgeDalga'
    if ($b) { $b.Content = (U "4 B\u00F6lge Z\u0131t Dalga") }
}

function Start-BolgeAnimasyon {
    # Animasyonu ayri bir surecte baslatir; panel kapansa da donmeye devam eder.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $IteScript + '"'))
    $argList += @('-Komut','bolgedalga','-Parlaklik',([string][int]$SldParlaklik.Value),'-Hiz',([string][int]$SldHiz.Value))
    if ($ChkKaydet.IsChecked) { $argList += '-Kaydet' } else { $argList += '-Gecici' }
    try {
        $p = Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -PassThru
        $script:BolgeDalgaProc = $p
        try { Set-Content -Path $script:BolgePidFile -Value ([string]$p.Id) -Encoding ASCII } catch {}
        $TxtLog.Text = (U "[OK] 4 B\u00F6lge Z\u0131t Dalga ba\u015Flad\u0131 (rastgele renkler). Ba\u015Fka efekt se\u00E7ene kadar d\u00F6ner.")
    } catch {
        $TxtLog.Text = ("[HATA] Animasyon baslatilamadi: " + $_.Exception.Message)
    }
}

function Invoke-IteCommand([string]$Komut, [string]$Arg1 = "") {
    $bri = [int]$SldParlaklik.Value
    $spd = [int]$SldHiz.Value
    $params = @{
        Komut     = $Komut
        Parlaklik = $bri
        Hiz       = $spd
    }
    if ($Arg1 -ne "") { $params["Arg1"] = $Arg1 }
    if ($ChkKaydet.IsChecked) { $params["Kaydet"] = $true } else { $params["Gecici"] = $true }
    if ($ChkStatikMod.IsChecked) { $params["StatikMod"] = $true }
    if ($ChkServisYenile.IsChecked -and $Komut -ne "tani") { $params["ServisYenile"] = $true }

    try {
        $out = & $IteScript @params 6>&1 | Out-String
        $lines = @(($out -split "`r?`n") | Where-Object { $_.Trim() -ne "" })
        if ($lines.Count -gt 0) {
            $TxtLog.Text = "$($lines[-1])".Trim()
        }
        return $out
    } catch {
        $TxtLog.Text = "[HATA] $($_.Exception.Message)"
        return ""
    }
}

function Set-RgbAvailable([bool]$available) {
    # Klavye takili degilse RGB kumandalarini devre disi birak.
    if ($script:RgbAvailable -eq $available) { return }
    $script:RgbAvailable = $available
    $rgbControls = @(
        'SldParlaklik','BtnParlaklikUygula','SldHiz',
        'BtnBri0','BtnBri8','BtnBri22','BtnBri36','BtnBri50',
        'BtnRenkKirmizi','BtnRenkYesil','BtnRenkMavi','BtnRenkBeyaz','BtnRenkSicakBeyaz',
        'BtnRenkSari','BtnRenkTuruncu','BtnRenkMor','BtnRenkTurkuaz','BtnRenkPembe',
        'SldR','SldG','SldB','BtnRenkSecici','BtnOzelRenkUygula',
        'BtnEfektOrijinal','BtnEfektAurora','BtnEfektDalga','BtnEfektTersDalga','BtnEfektDikeyDalga',
        'BtnEfektYukariDalga','BtnEfektNefes','BtnEfektNeon','BtnEfektNeonDalga','BtnEfektLav',
        'BtnEfektKuzey','BtnEfektAltin','BtnEfektZehir','BtnEfektSakura','BtnEfektYagmur','BtnEfektBolgeDalga',
        'BtnTemaOyuncu','BtnTemaMoba','BtnTemaKeskin','BtnTemaTurkBayragi','BtnTemaSiber',
        'BtnTemaRetro','BtnTemaGalaksi','BtnTemaMatrix','BtnTemaGunbatimi','BtnTemaOkyanus',
        'BtnTemaAtesBuz','BtnTemaGokkusagiSabit','BtnKapat','BtnTani','ChkKaydet','ChkStatikMod','ChkServisYenile'
    )
    foreach ($n in $rgbControls) {
        $c = Get-Control $n
        if ($c) {
            $c.IsEnabled = $available
            $c.Opacity = if ($available) { 1.0 } else { 0.45 }
        }
    }
    $env = Get-Control 'BrdOnizleme'
    if ($env) { $env.Opacity = if ($available) { 1.0 } else { 0.45 } }
}

function Update-DeviceStatus {
    $out = Invoke-IteCommand "tani"
    $fw = "?"
    # Klavye takili degil mi?
    if ($out -match 'bulunamadi|Device acilamadi') {
        Set-RgbAvailable $false
        $TxtCihazDurum.Text = (U "ITE 8291 RGB klavye bu bilgisayarda takili degil. Fan/guc sensorleri calismaya devam eder.")
        $TxtLog.Text = (U "[!] ITE 8291 (048D:600B) bulunamadi - RGB kontrolu devre disi.")
        return
    }
    Set-RgbAvailable $true
    if ($out -match 'Firmware\s*:\s*([^\r\n]+)') { $fw = $Matches[1].Trim() }
    if ($out -match 'Kapali mi\s*:\s*(True|False)\s+Efekt=0x([0-9A-Fa-f]+)\s+Hiz=(\d+)\s+Parlaklik=(\d+)') {
        $kapali = ($Matches[1] -eq "True")
        $efCode = [Convert]::ToInt32($Matches[2], 16)
        $hizVal = [int]$Matches[3]
        $briVal = [int]$Matches[4]
        $efAd   = if ($EfektAdlari.ContainsKey($efCode)) { $EfektAdlari[$efCode] } else { ("0x{0:X2}" -f $efCode) }
        $durum  = if ($kapali) { "KAPALI" } else { (U "A\u00C7IK - ") + $efAd }
        $TxtCihazDurum.Text = (U "Firmware: $fw   |   Durum: $durum   |   Parlakl\u0131k: $briVal/50   |   H\u0131z: $hizVal")
        if (-not $kapali -and $briVal -ge 0 -and $briVal -le 50) {
            $SldParlaklik.Value = $briVal
        }
        if ($hizVal -ge 1 -and $hizVal -le 10) {
            $SldHiz.Value = $hizVal
        }
        $TxtLog.Text = (U "[OK] Cihaz durumu g\u00FCncellendi ($durum)")
    } else {
        $TxtCihazDurum.Text = (U "Cihaz yan\u0131t\u0131 al\u0131namad\u0131.")
    }
}

function Update-RgbPreview {
    $r = [byte][int]$SldR.Value
    $g = [byte][int]$SldG.Value
    $b = [byte][int]$SldB.Value
    $TxtR.Text = "$r"
    $TxtG.Text = "$g"
    $TxtB.Text = "$b"
    $hex = "#{0:X2}{1:X2}{2:X2}" -f $r, $g, $b
    $TxtHex.Text = $hex
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r, $g, $b))
    $BrdOnizleme.Background = $brush
    $luma = (0.299 * $r) + (0.587 * $g) + (0.114 * $b)
    $TxtHex.Foreground = if ($luma -gt 150) { [System.Windows.Media.Brushes]::Black } else { [System.Windows.Media.Brushes]::White }
}

$SldParlaklik.Add_ValueChanged({
    $TxtParlaklik.Text = "$([int]$SldParlaklik.Value) / 50"
})
$SldHiz.Add_ValueChanged({
    $TxtHiz.Text = (U "$([int]$SldHiz.Value) (1=H\u0131zl\u0131)")
})

$SldR.Add_ValueChanged({ Update-RgbPreview })
$SldG.Add_ValueChanged({ Update-RgbPreview })
$SldB.Add_ValueChanged({ Update-RgbPreview })

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$BtnAdmin = Get-Control "BtnAdmin"
if ($IsAdmin) {
    $BtnAdmin.Visibility = [System.Windows.Visibility]::Collapsed
    $Window.Title = (U "ITE 8291 RGB Klavye Kontrol Paneli (Y\u00F6netici)")
} else {
    $BtnAdmin.Add_Click({
        try {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$PSCommandPath`"" -Verb RunAs
            $Window.Close()
        } catch {
            $TxtLog.Text = (U "[!] Y\u00F6netici izni iptal edildi.")
        }
    })
}

(Get-Control "BtnTani").Add_Click({ Update-DeviceStatus })
(Get-Control "BtnKapat").Add_Click({
    $RestoreTimer.Stop()
    [void](Invoke-IteCommand "kapat")
    Update-DeviceStatus
})
(Get-Control "BtnMonGosterge").Add_Click({ Show-SystemSnapshot "gosterge" })
(Get-Control "BtnMonPil").Add_Click({ Show-SystemSnapshot "pil" })

# Fan Kontrol: REA ölçümüyle doğrulanmış profil eşlemesi (0x751 + 0x7DA TCC).
# OEM servisi açıksa yazım bir süre sonra ezilebilir; buton sonrası EC okunup raporlanır.
$SldFanManuel.Add_ValueChanged({
    $TxtFanManuel.Text = "%$([int]$SldFanManuel.Value)"
})

function Show-FanResult([string]$label, [string]$color) {
    $TxtFanModDurum.Text = $label
    $TxtFanModDurum.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(
        [Convert]::ToInt32($color.Substring(0,2),16), [Convert]::ToInt32($color.Substring(2,2),16), [Convert]::ToInt32($color.Substring(4,2),16)))
    Update-EcSensors
}

# Ortak profil uygulama: yazar, kısa bekler, EC'den gerçek modu okuyup dürüst raporlar.
function Set-FanProfil([string]$ad, [string]$beklenen, [string]$color, [scriptblock]$yaz) {
    $before = [EcSensor]::ReadProfileName()
    $ok = & $yaz
    Start-Sleep -Milliseconds 900
    $after = [EcSensor]::ReadProfileName()
    if (-not $ok) {
        $TxtLog.Text = (U "[!] EC'ye yazılamadı (sürücü kapalı ya da izin yok). Değişiklik uygulanmadı.")
    } elseif ($after -ne $beklenen) {
        $TxtLog.Text = (U "[i] $ad istendi; EC şu an '$after' gösteriyor (OEM servisi eziyor olabilir).")
    } else {
        $TxtLog.Text = (U "[OK] Mod: $ad  (önce: $before → şimdi: $after)")
    }
    Show-FanResult (U "Mod: $after") $color
}

(Get-Control "BtnProfilOfis").Add_Click({
    Set-FanProfil (U "Ofis") (U "Ofis") '22C55E' { [EcSensor]::SetProfileOfis() }
})

(Get-Control "BtnProfilDengeli").Add_Click({
    Set-FanProfil (U "Dengeli") (U "Dengeli") '2DD4BF' { [EcSensor]::SetProfileDengeli() }
})

(Get-Control "BtnProfilTurboSessiz").Add_Click({
    Set-FanProfil (U "Turbo / Sessiz") (U "Turbo / Sessiz") 'A78BFA' { [EcSensor]::SetProfileTurboSessiz() }
})

(Get-Control "BtnProfilTurboEkstrem").Add_Click({
    Set-FanProfil (U "Turbo / Ekstrem") (U "Turbo / Ekstrem") 'F59E0B' { [EcSensor]::SetProfileTurboEkstrem() }
})

(Get-Control "BtnFanManuelUygula").Add_Click({
    $pct = [int]$SldFanManuel.Value
    [void][EcSensor]::SetFanManualSpeed($pct)
    $TxtLog.Text = (U "[i] Fan: %$pct duty isteği gönderildi (EC bu makinada duty yazımını yok sayar)")
})

(Get-Control "BtnOemDurumYenile").Add_Click({
    $m = [EcSensor]::ReadProfileName()
    Show-FanResult (U "Mod: $m") '38BDF8'
    $TxtLog.Text = (U "[OK] EC fan modu okundu: $m")
})

(Get-Control "BtnAcOemCenter").Add_Click({
    # Resmi OEM Kontrol Merkezi (UWP: ControlCenter3) uygulamasını aç.
    try {
        Start-Process 'explorer.exe' 'shell:AppsFolder\ControlCenter3_wrbgcf7aesyd8!App'
        $TxtLog.Text = (U "[OK] Kontrol Merkezi açılıyor...")
    } catch {
        # fallback: GCUService/GCU launcher
        try {
            Start-Process 'C:\Program Files\OEM\Kontrol Merkezi\AiStoneService\MyControlCenter\GCUService.exe'
            $TxtLog.Text = (U "[OK] GCUService başlatıldı.")
        } catch {
            $TxtLog.Text = (U "[!] Kontrol Merkezi açılamadı: " + $_.Exception.Message)
        }
    }
})


(Get-Control "BtnParlaklikUygula").Add_Click({
    [void](Invoke-IteCommand "parlaklik")
    Update-DeviceStatus
})

foreach ($lvl in @(0, 8, 22, 36, 50)) {
    $btn = Get-Control "BtnBri$lvl"
    $val = $lvl
    $btn.Add_Click({
        $SldParlaklik.Value = $val
        [void](Invoke-IteCommand "parlaklik")
        Update-DeviceStatus
    }.GetNewClosure())
}

$RenkButonlari = @{
    BtnRenkKirmizi    = "kirmizi"
    BtnRenkYesil      = "yesil"
    BtnRenkMavi       = "mavi"
    BtnRenkBeyaz      = "beyaz"
    BtnRenkSicakBeyaz = "sicakbeyaz"
    BtnRenkSari       = "sari"
    BtnRenkTuruncu    = "turuncu"
    BtnRenkMor        = "mor"
    BtnRenkTurkuaz    = "turkuaz"
    BtnRenkPembe      = "pembe"
}
foreach ($kv in $RenkButonlari.GetEnumerator()) {
    $btn = Get-Control $kv.Key
    $renkAdi = $kv.Value
    $btn.Add_Click({
        $RestoreTimer.Stop()
        $script:SonEfektKomutu = "renk"
        $script:SonEfektArg = $renkAdi
        if ([int]$SldParlaklik.Value -eq 0) { $SldParlaklik.Value = 50 }
        [void](Invoke-IteCommand "renk" $renkAdi)
        Update-DeviceStatus
    }.GetNewClosure())
}

(Get-Control "BtnRenkSecici").Add_Click({
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    $dlg.Color = [System.Drawing.Color]::FromArgb([int]$SldR.Value, [int]$SldG.Value, [int]$SldB.Value)
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $SldR.Value = $dlg.Color.R
        $SldG.Value = $dlg.Color.G
        $SldB.Value = $dlg.Color.B
        Update-RgbPreview
        if ([int]$SldParlaklik.Value -eq 0) { $SldParlaklik.Value = 50 }
        [void](Invoke-IteCommand "renk" "$($dlg.Color.R),$($dlg.Color.G),$($dlg.Color.B)")
        Update-DeviceStatus
    }
})

(Get-Control "BtnOzelRenkUygula").Add_Click({
    if ([int]$SldParlaklik.Value -eq 0) { $SldParlaklik.Value = 50 }
    $rgbStr = "$([int]$SldR.Value),$([int]$SldG.Value),$([int]$SldB.Value)"
    [void](Invoke-IteCommand "renk" $rgbStr)
    Update-DeviceStatus
})

$EfektButonlari = @{
    BtnEfektOrijinal       = "orijinal"
    BtnEfektAurora         = "aurora"
    BtnEfektDalga          = "dalga"
    BtnEfektTersDalga      = "tersdalga"
    BtnEfektDikeyDalga     = "dikeydalga"
    BtnEfektYukariDalga    = "yukaridalga"
    BtnEfektNefes          = "nefes"
    BtnEfektNeon           = "neon"
    BtnEfektNeonDalga      = "neondalga"
    BtnEfektLav            = "lav"
    BtnEfektKuzey          = "kuzey"
    BtnEfektAltin          = "altin"
    BtnEfektZehir          = "zehir"
    BtnEfektSakura         = "sakura"
    BtnEfektYagmur         = "yagmur"
    BtnEfektBolgeDalga     = "bolgedalga"
    BtnTemaOyuncu          = "oyuncu"
    BtnTemaMoba            = "moba"
    BtnTemaKeskin          = "keskin"
    BtnTemaTurkBayragi     = "turkbayragi"
    BtnTemaSiber           = "siber"
    BtnTemaRetro           = "retro"
    BtnTemaGalaksi         = "galaksi"
    BtnTemaMatrix          = "matrix"
    BtnTemaGunbatimi       = "gunbatimi"
    BtnTemaOkyanus         = "okyanus"
    BtnTemaAtesBuz         = "atesbuz"
    BtnTemaGokkusagiSabit  = "gokkusagisabit"
}
foreach ($kv in $EfektButonlari.GetEnumerator()) {
    $btn = Get-Control $kv.Key
    $efKomut = $kv.Value
    $btn.Add_Click({
        $RestoreTimer.Stop()
        $script:SonEfektKomutu = $efKomut
        $script:SonEfektArg = ""
        if ([int]$SldParlaklik.Value -eq 0) { $SldParlaklik.Value = 36 }
        # Once onceki efektin animasyonunu durdur (varsa).
        Stop-BolgeAnimasyon
        if ($efKomut -eq 'bolgedalga') {
            # Diger efektler gibi tek tikla baslar ve kullanici degistirene kadar doner.
            Start-BolgeAnimasyon
        } else {
            [void](Invoke-IteCommand $efKomut)
            Update-DeviceStatus
        }
    }.GetNewClosure())
}

Update-RgbPreview
Update-EcSensors
Update-DeviceStatus
Update-FanBoostButton

# Onceki oturumdan calisan bir bolge animasyonu varsa butonu isaretleyip hatirlat.
try {
    if (Test-Path $script:BolgePidFile) {
        $oldPid = [int](Get-Content -Raw $script:BolgePidFile).Trim()
        $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'powershell') {
            $bb = Get-Control 'BtnEfektBolgeDalga'
            if ($bb) { $bb.Content = (U "4 B\u00F6lge Dalga (\u00E7al\u0131\u015F\u0131yor)") }
        } else {
            Remove-Item $script:BolgePidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

if ($TestYukle) {
    Write-Host "[OK] Panel basariyla yuklendi -> $($TxtCihazDurum.Text)" -ForegroundColor Green
    Write-Host "     EC Sensorleri -> CPU: $($TxtEcCpuTemp.Text) ($($TxtEcCpuFan.Text)) | GPU: $($TxtEcGpuTemp.Text) ($($TxtEcGpuFan.Text))" -ForegroundColor Cyan
    exit 0
}

[void]$Window.ShowDialog()
