# ITE8291_R9T3D_KONTROL_PANEL

**[Türkçe](#türkçe) · [English](#english)**

---

## Türkçe

Game Garaj Slayer R9T (ITE8291 3-bölge RGB klavye) için bağımsız bir PowerShell kontrol paneli.
Resmî Kontrol Merkezi'ne **alternatif değil**, onun yanında çalışan bir **hobi projesidir**.

### ⚠️ Sorumluluk Reddi

Bu proje **sorumluluk kabul etmez**. Tamamen hobi amaçlı, ücretsiz ve "olduğu gibi" (AS IS) sunulur.
Hasarlı cihaz riski, veri kaybı, garanti kapsamı, donanım arızası veya herhangi bir zarardan
yazar(lar) **sorumlu tutulamaz**. Kullanım tamamen sizin sorumluluğunuzdadır.

- Donanım register'larına yazan kod içerir. **Yönetici izniyle** çalışır.
- EC (Embedded Controller) yazımları geri alınabilir olsa da, yanlış kullanım fan davranışını
  geçici olarak etkileyebilir. Elektrik kesintisi/ yeniden başlatma çoğunu sıfırlar.
- Bu projeyi kullanmadan önce **Kontrol Merkezi'nin yaptığı işi kopyaladığını** unutmayın;
  elle register yazımı üretici tarafından desteklenmez.

**Desteklenen tek model:** Game Garaj Slayer R9T. Başka modellerde denenmemiştir.

### 🛠️ Ne yapar?

| Özellik | Durum |
|---|---|
| RGB efektler (dalga, nefes, gökkuşağı, statik, 4-bölge kayan dalga) | ✅ Çalışıyor |
| Renk (RGB), parlaklık (0–50), hız (1–10) | ✅ Çalışıyor |
| Sıcak/soğuk/ve tema hazır renkleri | ✅ Çalışıyor |
| **Gerçek fan modu göstergesi (EC'den canlı okuma)** | ✅ Çalışıyor |
| **Fan profili değiştirme** (Ofis / Dengeli / Turbo-Sessiz / Turbo-Ekstrem) | ✅ Çalışıyor |
| CPU/GPU sıcaklık, fan RPM + duty, GPU watt | ✅ Çalışıyor |
| Anlık CPU/RAM ve pil OSD barı | ✅ Çalışıyor |

> **Not:** Resmî Kontrol Merkezi, donanım mod tuşuyla yapılan değişikliği *göstermez*
> (kendi kayıtlı değerini okur). Bu panel **EC'yi canlı okuduğu için** donanım tuşunu da yakalar.
> Asıl motivasyonumuz buydu.

### 🚀 Kullanım

Yönetici olarak `panel.bat` çalıştırın (kendini yükseltir).

Komut satırından `ite.ps1`:

```powershell
# Tanı / cihaz durumu
.\ite.ps1 tanı

# Fan modları
.\ite.ps1 fan oto        # Dengeli (EC normal eğrisi)
.\ite.ps1 fan boost      # Turbo

# Aktiviteyi kapat / fabrika rengi
.\ite.ps1 kapat -Kaydet
.\ite.ps1 orijinal -Parlaklik 36
```

Ya da hazır `.bat` dosyaları: `kapat.bat`, `renk.bat`, `orijinal.bat`.

### 🔬 Fan register haritası (doğrulanmış)

REA ile yapılan ölçümler, resmî uygulama mod değiştirirken sadece okuyarak:

| Mod | `0x751` | `0x7DA` (TCC) | `0x744` (TGP) |
|---|---|---|---|
| Ofis | `0xA0` | 95 | 0 |
| Dengeli | `0x00` | 95 | 50 |
| Turbo / Sessiz | `0x10` | 95 | 50 |
| Turbo / Ekstrem | `0x10` | 97 | 50 |

- `0x767` (TRIGGER) **her zaman `0x00`**; resmî uygulama bu bayrağı kullanmıyor.
- `0x75B` / `0x75C` (CPU/GPU duty) EC tarafından hesaplanır; yazım **yok sayılır**.

### 📋 Gereksinimler

- Windows 10 / 11 (x64)
- PowerShell 5.1+ (**UTF-8 BOM** ile kaydedilmiş `.ps1` — dosyalar zaten BOM'lu)
- ITE8291 klavye: `HID\VID_048D&PID_600B&MI_01`
- EC erişimi için: `\\.\ACPIDriver` (Uniwill `UWACPIDriver.sys` — sistemle gelir)

### 📄 Lisans

Kişisel/hobi kullanım için serbest. Üretim veya ticari kullanım için uygun **değildir**.
Resmî Kontrol Merkezi ve donanım üreticisiyle **hiçbir bağlantısı yoktur**.

---

## English

An independent PowerShell control panel for the **Game Garaj Slayer R9T** (ITE8291 3-zone RGB keyboard).
Not a replacement for the official Control Center — a **hobby project** that runs alongside it.

### ⚠️ Disclaimer

This project provides **no warranty**. It is a free, hobby project provided **AS IS**.
The author(s) **accept no liability** for damaged hardware, data loss, warranty voidance,
device malfunction, or any other damage. Use entirely at your own risk.

- It writes to hardware registers. It runs **with administrator rights**.
- EC (Embedded Controller) writes are reversible, but misuse can temporarily affect fan behaviour.
  A power cycle / reboot resets most of it.
- This project replicates what the official Control Center does. Manual register writes are
  **not vendor-supported**.

**Only supported model:** Game Garaj Slayer R9T. Not tested on other models.

### 🛠️ Features

| Feature | Status |
|---|---|
| RGB effects (wave, breathing, rainbow, static, 4-zone scrolling wave) | ✅ Works |
| Colour (RGB), brightness (0–50), speed (1–10) | ✅ Works |
| Warm/cool/theme presets | ✅ Works |
| **Real fan mode display (live EC read)** | ✅ Works |
| **Fan profile switching** (Office / Balanced / Turbo-Quiet / Turbo-Extreme) | ✅ Works |
| CPU/GPU temp, fan RPM + duty, GPU watt | ✅ Works |
| Live CPU/RAM and battery OSD bar | ✅ Works |

> **Note:** The official Control Center does *not* reflect changes made with the hardware mode
> button (it reads its own stored value). This panel **reads the EC live**, so it also catches
> hardware button changes. That was the whole motivation.

### 🚀 Usage

Run `panel.bat` as administrator (it self-elevates).

From the command line with `ite.ps1`:

```powershell
.\ite.ps1 tanı          # diagnostics / device status
.\ite.ps1 fan oto       # Balanced (EC normal curve)
.\ite.ps1 fan boost     # Turbo
.\ite.ps1 kapat -Kaydet # stop activity
.\ite.ps1 orijinal -Parlaklik 36
```

Or use the bundled `.bat` helpers: `kapat.bat`, `renk.bat`, `orijinal.bat`.

### 🔬 Fan register map (verified)

Measured with REA by passively reading the EC while the official app switched modes:

| Mode | `0x751` | `0x7DA` (TCC) | `0x744` (TGP) |
|---|---|---|---|
| Office | `0xA0` | 95 | 0 |
| Balanced | `0x00` | 95 | 50 |
| Turbo / Quiet | `0x10` | 95 | 50 |
| Turbo / Extreme | `0x10` | 97 | 50 |

- `0x767` (TRIGGER) is **always `0x00`**; the official app does not use it.
- `0x75B` / `0x75C` (CPU/GPU duty) are computed by the EC; writes are **ignored**.

### 📋 Requirements

- Windows 10 / 11 (x64)
- PowerShell 5.1+ (`.ps1` files must be **UTF-8 with BOM**; the bundled files already are)
- ITE8291 keyboard: `HID\VID_048D&PID_600B&MI_01`
- EC access via `\\.\ACPIDriver` (Uniwill `UWACPIDriver.sys` — ships with the system)

### 📄 License

Free for personal/hobby use. **Not** suitable for production or commercial use.
Not affiliated with the official Control Center or the hardware vendor.
