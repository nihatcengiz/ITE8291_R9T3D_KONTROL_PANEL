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

- Donanım register'larına ve HID cihazına yazan kod içerir. **Yönetici izniyle** çalışır.
- EC (Embedded Controller) yazımları geri alınabilir olsa da, yanlış kullanım fan davranışını
  geçici olarak etkileyebilir. Elektrik kesintisi / yeniden başlatma çoğunu sıfırlar.
- Bu projeyi kullanmadan önce **Kontrol Merkezi'nin yaptığı işi kopyaladığını** unutmayın;
  elle register yazımı üretici tarafından desteklenmez.

**Desteklenen tek model:** Game Garaj Slayer R9T. Başka modellerde denenmemiştir.

### 🛠️ Ne yapar?

| Özellik | Durum |
|---|---|
| RGB efektler (16 donanım efekti: gökkuşağı, aurora, dalga, nefes, neon, lav, sakura, yağmur, rastgele…) | ✅ Çalışıyor |
| 12 per-key gradyan teması (FPS, MOBA, Cyberpunk, Matrix, Okyanus…) | ✅ Çalışıyor |
| Renk (RGB), parlaklık (0–50), hız (1–10) | ✅ Çalışıyor |
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

# Donanım efektleri
.\ite.ps1 dalga -Parlaklik 40 -Hiz 5
.\ite.ps1 rastgele
.\ite.ps1 nefes ; .\ite.ps1 aurora ; .\ite.ps1 lav ; .\ite.ps1 sakura

# Tüm tuşlar tek renk
.\ite.ps1 renk kirmizi -Parlaklik 40

# Fan profilleri
.\ite.ps1 fan oto        # Dengeli
.\ite.ps1 fan boost      # Turbo

# Aktiviteyi kapat / fabrika rengi
.\ite.ps1 kapat -Kaydet
.\ite.ps1 orijinal -Parlaklik 36
```

Ya da hazır `.bat` dosyaları: `kapat.bat`, `renk.bat`, `orijinal.bat`.

### 🔬 Fan register haritası (doğrulanmış)

Ayrıntı: [FAN_REGISTERS.md](FAN_REGISTERS.md)

| Mod | `0x751` | `0x7DA` (TCC) | `0x744` (TGP) |
|---|---|---|---|
| Ofis | `0xA0` | 95 | 0 |
| Dengeli | `0x00` | 95 | 50 |
| Turbo / Sessiz | `0x10` | 95 | 50 |
| Turbo / Ekstrem | `0x10` | 97 | 50 |

- `0x767` (TRIGGER) **her zaman `0x00`**; resmî uygulama bu bayrağı kullanmıyor.
- `0x75B` / `0x75C` (CPU/GPU duty) EC tarafından hesaplanır; yazım **yok sayılır**.

### ⚠️ Bilinen donanım sınırı

**Yazılım tabanlı (kare kare hesaplanan) animasyonlar bu donanımda KULLANILMAZ.**
Sürekli HID yazımı (saniyede ~100+ paket) ITE8291 firmware'ini kilitleyebiliyor: cihaz USB'den
düşer, OEM servisi de klavyeyi göremez ve düzelmesi için **soğuk açma (power cycle)** gerekir.
Bu yüzden 4-bölge dalga ve sinüs dalgası efektleri kaldırılmıştır.

Paneldeki tüm efektler **firmware'de çalışır**: tek bir komutla set edilir, sonra donanım kendi
kendine döner. Sürekli yazım yoktur, bu risk oluşmaz.

### 📋 Gereksinimler

- Windows 10 / 11 (x64)
- PowerShell 5.1+ (`.ps1` dosyaları **UTF-8 BOM** ile kayıtlı olmalı — bundled dosyalar öyle)
- ITE8291 klavye: `HID\VID_048D&PID_600B&MI_01`
- EC erişimi: `\\.\ACPIDriver` (Uniwill `UWACPIDriver.sys` — sistemle gelir)

### 🔗 İlgili projeler

- [MrSpy00/mrSpyCC](https://github.com/MrSpy00/mrSpyCC) — Windows/C#, ~60 efekt + mini oyunlar (RGB protokolü bağımsız olarak aynı bulundu)
- [yusufcanyavic/YYavic-Control-Center](https://github.com/yusufcanyavic/YYavic-Control-Center) — macOS/Swift, aynı firmware 34.3.0.0
- [salihmarangoz/system_tray_extensions](https://github.com/salihmarangoz/system_tray_extensions) — Linux/Python, yazılım efektleri (sinüs buradan uyarlandı)

Bu projelerin hiçbirinde fan kontrolü yoktur; bu reponun özgün katkısı fan mod haritasıdır.

### 📄 Lisans

Kişisel / hobi kullanım için serbest. Üretim veya ticari kullanım için uygun **değildir**.
Resmî Kontrol Merkezi ve donanım üreticisiyle **hiçbir bağlantısı yoktur**.

---

## English

An independent PowerShell control panel for the **Game Garaj Slayer R9T** (ITE8291 3-zone RGB keyboard).
Not a replacement for the official Control Center — a **hobby project** that runs alongside it.

### ⚠️ Disclaimer

This project provides **no warranty**. It is a free, hobby project provided **AS IS**.
The author(s) **accept no liability** for damaged hardware, data loss, warranty voidance,
device malfunction, or any other damage. Use entirely at your own risk.

- It writes to hardware registers and to a HID device. It runs **with administrator rights**.
- EC (Embedded Controller) writes are reversible, but misuse can temporarily affect fan behaviour.
  A power cycle / reboot resets most of it.
- This project replicates what the official Control Center does. Manual register writes are
  **not vendor-supported**.

**Only supported model:** Game Garaj Slayer R9T. Not tested on other models.

### 🛠️ Features

| Feature | Status |
|---|---|
| RGB effects (16 firmware effects: rainbow, aurora, wave, breathing, neon, lava, sakura, rain, random…) | ✅ Works |
| 12 per-key gradient themes (FPS, MOBA, Cyberpunk, Matrix, Ocean…) | ✅ Works |
| Colour (RGB), brightness (0–50), speed (1–10) | ✅ Works |
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
.\ite.ps1 dalga -Parlaklik 40 -Hiz 5
.\ite.ps1 rastgele
.\ite.ps1 renk kirmizi -Parlaklik 40
.\ite.ps1 fan oto       # Balanced
.\ite.ps1 fan boost     # Turbo
.\ite.ps1 kapat -Kaydet
```

Or use the bundled `.bat` helpers: `kapat.bat`, `renk.bat`, `orijinal.bat`.

### 🔬 Fan register map (verified)

Details: [FAN_REGISTERS.md](FAN_REGISTERS.md)

| Mode | `0x751` | `0x7DA` (TCC) | `0x744` (TGP) |
|---|---|---|---|
| Office | `0xA0` | 95 | 0 |
| Balanced | `0x00` | 95 | 50 |
| Turbo / Quiet | `0x10` | 95 | 50 |
| Turbo / Extreme | `0x10` | 97 | 50 |

- `0x767` (TRIGGER) is **always `0x00`**; the official app does not use it.
- `0x75B` / `0x75C` (CPU/GPU duty) are computed by the EC; writes are **ignored**.

### ⚠️ Known hardware limitation

**Software-driven (per-frame) animations are NOT used on this hardware.**
Continuous HID writes (~100+ packets/sec) can lock up the ITE8291 firmware: the device drops off
USB, the OEM service can no longer see the keyboard, and a **cold power cycle** is required to
recover. For this reason the 4-zone wave and sine wave effects have been removed.

Every effect in the panel runs **on the firmware**: set once with a single command, then the
hardware animates on its own. There are no continuous writes, so this risk does not occur.

### 📋 Requirements

- Windows 10 / 11 (x64)
- PowerShell 5.1+ (`.ps1` files must be **UTF-8 with BOM**; the bundled files already are)
- ITE8291 keyboard: `HID\VID_048D&PID_600B&MI_01`
- EC access via `\\.\ACPIDriver` (Uniwill `UWACPIDriver.sys` — ships with the system)

### 🔗 Related projects

- [MrSpy00/mrSpyCC](https://github.com/MrSpy00/mrSpyCC) — Windows/C#, ~60 effects + mini games (independently found the same RGB protocol)
- [yusufcanyavic/YYavic-Control-Center](https://github.com/yusufcanyavic/YYavic-Control-Center) — macOS/Swift, same firmware 34.3.0.0
- [salihmarangoz/system_tray_extensions](https://github.com/salihmarangoz/system_tray_extensions) — Linux/Python, software effects (the sine wave was adapted from here)

None of these projects implement fan control; the original contribution of this repo is the fan mode map.

### 📄 License

Free for personal/hobby use. **Not** suitable for production or commercial use.
Not affiliated with the official Control Center or the hardware vendor.
