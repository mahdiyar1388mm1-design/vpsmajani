# vpsmajani — ویندوز ابری همیشه‌روشن + فایل‌هایی که پاک نمی‌شوند

یک ماشین ویندوز روی GitHub Actions با Remote Desktop و Tailscale که:
1. **هیچ‌وقت تموم نمی‌شود** — هر سشن خودش سشن بعدی را استارت می‌زند.
2. **فایل‌هایت پاک نمی‌شوند** — قبل از مرگ هر سشن، یک snapshot از پروفایل کاربر گرفته می‌شود و سشن بعدی آن را برمی‌گرداند.

---

## مهم: محدودیت ۶ ساعته

هر جاب روی رانر GitHub حداکثر ۶ ساعت زنده می‌ماند؛ این سقف زیرساختی است و با `timeout-minutes` بالا نمی‌رود. برای همین زنجیره‌ای از سشن‌های ~۳۰ دقیقه‌ای ساخته‌ام که هر کدام قبل از پایانش، سشن بعدی را از طریق GitHub API دیسپچ می‌کند. `MAX_CHAIN` پیش‌فرض `0` یعنی **بی‌نهایت**.

---

## معماری نگه‌داری فایل‌ها

```
سشن N (ویندوز)                     VPS ذخیره‌سازی (همیشه روشن)
   │  هر ۱۰ دقیقه + پایان سشن          │  /mnt/vpsmajani
   ├────── snapshot (tar.gz) ─────────►│  snapshot-0.tar.gz
   │                                  │  snapshot-1.tar.gz
سشن N+1 (VM تازه)                     │  snapshot-2.tar.gz
   │◄─────── restore ─────────────────┤  + last-save.txt
   │  فایل‌ها سر جایشان برمی‌گردند      │
```

- **چه چیزی نگه داشته می‌شود:** کل `C:\Users\NvDAdmin` — یعنی Desktop، Documents، Downloads، Pictures، AppData (پروفایل مرورگر، تاریخچه چت، تنظیمات برنامه‌ها).
- **چه چیزی نه:** کش‌ها و فایل‌های موقت (`AppData\Local\Temp`، کش Edge/Chrome، `Packages\*\LocalCache`، pagefile). فهرست کامل در `.github/scripts/sync-common.ps1` تابع `Get-SyncExcludes`.
- **چه زمانی:** هر ۱۰ دقیقه داخل سشن + یک بار در پایان سشن. اگر VM یک‌دفعه کشته شود، نهایتاً ~۱۰ دقیقه کار از دست می‌رود.
- **حجم:** snapshot فشرده است؛ برای چند صد مگابایت فایل معمولی، حدود ۱۰۰–۲۰۰ مگابایت. آخرین ۳ نسخه نگه داشته می‌شود.

> بدون VPS ذخیره‌سازی، زنجیره باز هم کار می‌کند ولی حالت `local` است و چیزی restore نمی‌شود. یعنی برای «پاک نشدن» باید یک‌بار VPS را راه بیندازی.

---

## راه‌اندازی

### ۱) VPS ذخیره‌سازی (یک بار، ~۱۰ دقیقه)

یک VPS ارزان بگیر (۱ هسته / ۱ گیگ رم / ۲۰ گیگ دیسک کافی است — Ubuntu/Debian) و:

```bash
# کلید Tailscale بساز (Reusable، بدون Ephemeral):
#   https://login.tailscale.com/admin/settings/keys

scp -r storage .github root@VPS_IP:/root/
ssh root@VPS_IP 'bash /root/storage/install.sh'
```

نصب‌کننده در پایان این‌ها را چاپ می‌کند و می‌گویی کجا بگذاری:

| نوع | نام | مقدار |
|---|---|---|
| Actions Variable | `STORAGE_URL` | `http://100.x.y.z:8787` |
| Actions Secret | `SYNC_TOKEN` | توکن تولیدشده |
| Actions Variable | `SYNC_MODE` | `http` (اختیاری، خودکار تشخیص داده می‌شود) |

جزئیات بیشتر: [`storage/README.md`](storage/README.md)

### ۲) گیت‌هاب

- Secretها: `TAILSCALE_AUTHKEY` (کلید Ephemeral+Reusable)، `RDP_PASSWORD` (اختیاری)، `SYNC_TOKEN` (از مرحله ۱)
- Variables: `STORAGE_URL`، و اگر خواستی `MAX_CHAIN=0` و `SYNC_MODE=http`

### ۳) اجرا

`Actions → Windows Cloud RDP (auto-renewing) → Run workflow`

بعد از چند دقیقه در لاگ:

```
Tailscale IP : 100.x.y.z
Username     : NvDAdmin
Password     : ****
Connect with : mstsc /v:100.x.y.z
```

با `mstsc` وصل شو. روی دسکتاپ فایل `STATUS.txt` هست که وضعیت restore و زمان‌بندی را نشان می‌دهد.

---

## سؤال‌هایی که احتمالاً داری

**«الان روی دسکتاپم چیزی نیست!»**
اولین سشن یک زنجیره، VM تازه است و چیزی برای restore ندارد. چیزی که در آن سشن بسازی، در پایانش save می‌شود و از سشن دوم به بعد برمی‌گردد. به `STATUS.txt` نگاه کن.

**«وسط کار پنجره RDP قطع شد.»**
سشن عوض شده. دوباره به همان نام/آی‌پی وصل شو؛ فایل‌ها سر جایشان هستند (شاید یک دقیقه طول بکشد).

**«فایل‌های بزرگ چه؟»**
تا وقتی زیر چند صد مگابایت بمانی راحت است. اگر ویدیو یا دیتاست بزرگ داری، آن را روی خود VPS ذخیره کن، نه روی ویندوز.

**«چطور خاموشش کنم؟»**
آخرین رانِ در حال اجرا و رانِ صف را Cancel کن. اگر watchdog را روشن کرده‌ای (`AUTO_RDP=on`)، اول آن را خاموش کن وگرنه دوباره زنده‌اش می‌کند.

---

## امنیت — جدی بگیر

- ریپو **public** است؛ رمز قبلی که داخل ورک‌فلو هاردکد شده بود را سوخته فرض کن و عوض کن.
- رمز جدید فقط از Secret یا تصادفی ساخته می‌شود و در لاگ ماسک است.
- RDP با دسترسی ادمین روی اینترنت خطرناک است. رمز قوی بگذار، بعد از کار خاموش کن.
- پورت ۸۷۸۷ سرویس ذخیره‌سازی فقط روی `tailscale0` باز است؛ روی اینترنت عمومی expose نکن.
- توکن ذخیره‌سازی در `/etc/vpsmajani-sync.token` روی VPS است.

---

## کارهای توسعه

| فایل | کار |
|---|---|
| `.github/workflows/windows-rdp.yml` | زنجیره سشن‌ها + save/restore |
| `.github/workflows/rdp-watchdog.yml` | اگر زنجیره مرد، دوباره زنده‌اش می‌کند (`AUTO_RDP=on`) |
| `.github/scripts/sync_server.py` | سرور snapshot (فقط stdlib) |
| `.github/scripts/desktop-save.ps1` | ساخت archive + آپلود |
| `.github/scripts/desktop-restore.ps1` | دانلود + بازکردن + بررسی sha256 |
| `.github/scripts/sync-common.ps1` | مسیرها، excludeها، ابزارها |
| `storage/install.sh` | نصب سرویس روی VPS |

تست‌ها (هر push خودکار اجرا می‌شوند):
- `Check PowerShell scripts` — پارس همه `.ps1`ها روی ویندوز واقعی
- `Test desktop save/restore` — چرخه کامل: ساخت فایل → آپلود → پاک‌کردن پروفایل → restore → مقایسه بایت‌به‌بایت + تست رد کردن آپلود خراب
