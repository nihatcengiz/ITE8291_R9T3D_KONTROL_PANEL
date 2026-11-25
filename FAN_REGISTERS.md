# EC Fan Mod Haritası — Game Garaj Slayer R9T

Gözlem yöntemi: Kontrol Merkezi'nden mod değiştirilirken `\\.\ACPIDriver` üzerinden
sadece EC register okundu (yazma yapılmadı). Her mod ~8-10 sn sabitlendikten
sonra 6-8 ardışık okuma alındı.

## Doğrulanmış eşleme

| Mod | `0x751` (FAN_CTRL) | `0x7DA` (TURBO_TCC) | `0x744` (TGP_VAL) | duty (0x75B/0x75C) |
|---|---|---|---|---|
| Ofis       | `0xA0` | 95 | 0  | 110 (%55, sabit) |
| Dengeli    | `0x00` | 95 | 50 | 136 (%68) |
| Turbo / Sessiz Performans  | `0x10` | 95 | 50 | ~134-159 |
| Turbo / Ekstrem Performans | `0x10` | 97 | 50 | 160-184 |

## `0x751` bayrakları

| Değer | Bitler | Anlam |
|---|---|---|
| `0x00` | —               | Dengeli (EC normal eğrisi) |
| `0x10` | bit4            | Turbo modu |
| `0xA0` | bit7 + bit5     | Ofis / sessiz |
| `0x40` | bit6            | force-max (ESKİ varsayım; güncel ölçümde görülmedi) |

## `0x767` (TRIGGER)

Tüm ölçümlerde **hep `0x00`**. OEM uygulaması bu bayrağı kullanmıyor.
Yani `0x767=0x04`'ün "force-max" olduğu eski gözlem, normal mod geçişlerinde
geçerli değil — trigger yazımı gerekmiyor.

## Güç limitleri (modla DEĞİŞMEDİ)

Sabit kalanlar: GAMING_PL1=75, PL2=85, PL4=85; OFFICE 45/45/45;
BAT 145/145/174; GAMING_TCC=95, OFFICE_TCC=95.

Modla değişen tek TCC: `0x7DA TURBO_TCC` = 97 (Ekstrem) / 95 (diğerleri).
Modla değişen tek TGP: `0x744 TGP_VAL` = 50 (Dengeli/Turbo) / 0 (Ofis).

## Panel için sonuç

Gerçek mod değişimi iki yazımla yapılabilir:
- Ofis:    `0x751=0xA0`, `0x7DA=95`
- Dengeli: `0x751=0x00`, `0x7DA=95`
- Turbo/Sessiz:  `0x751=0x10`, `0x7DA=95`
- Turbo/Ekstrem: `0x751=0x10`, `0x7DA=97`

NOT: OEM servisi (GCUService) açıkken bu yazımlar ezilebilir; servis kapalıyken
kalıcı olur. Trigger (0x767) yazımına gerek yok — hep 0x00.
