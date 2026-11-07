# storage/ — staging area for the persistent snapshot volume

ماشین ویندوزی که زنجیره می‌سازد هر ۴۰ دقیقه عوض می‌شود. برای اینکه فایل‌ها گم نشوند، هر سشن یک **snapshot** از پروفایل کاربر می‌گیرد و روی یک VPS کوچک همیشه‌روشن (داخل همان tailnet) می‌گذارد؛ سشن بعدی آن را برمی‌گرداند.

## راه‌اندازی (یک بار، روی VPS خودت)

روی یک VPS ارزان (۱ هسته / ۱ گیگ / ۱۰–۲۰ گیگ دیسک کافی است) و ترجیحاً Ubuntu/Debian:

```bash
# 1) کلید Tailscale بساز: https://login.tailscale.com/admin/settings/keys
#    این یکی برخلاف کلید ویندوز، Reusable باشد و Ephemeral نباشد.

# 2) این دو فایل را روی VPS کپی کن
scp storage/install.sh storage/sync_server.py root@YOUR_VPS:/root/

# 3) نصب
ssh root@YOUR_VPS 'bash /root/install.sh'
```

نصب‌کننده آخرش سه چیز چاپ می‌کند:

| کجا | نام | مقدار |
|---|---|---|
| GitHub → Variables | `STORAGE_URL` | `http://100.x.y.z:8787` |
| GitHub → Variables | `SYNC_MODE` | `http` |
| GitHub → Secrets | `SYNC_TOKEN` | توکن خودکار (یا با env بده) |

بعد از آن، ورک‌فلوی RDP خودش snapshot را می‌فرستد و برمی‌گرداند.

## چه چیزی نگه داشته می‌شود

- کل پروفایل `C:\Users\NvDAdmin` → Desktop، Documents، Downloads، Pictures، AppData (پروفایل مرورگر، چت‌ها، تنظیمات برنامه‌ها)
- کَش‌ها مستثنی هستند: `AppData\Local\Temp`، کش Edge/Chrome، `Packages\*\LocalCache`، فایل‌های page/swap. این‌ها را در `.github/scripts/sync-common.ps1` (`Get-SyncExcludes`) می‌بینی و می‌توانی تغییر دهی.

## زمان‌بندی

| لحظه | کار |
|---|---|
| هر ۱۰ دقیقه داخل سشن | snapshot دوره‌ای |
| پایان سشن (حتی timeout) | snapshot نهایی، قبل از مرگ VM |
| شروع سشن بعدی | restore |

یعنی اگر VM یک‌دفعه بمیرد، حداکثر حدود ۱۰ دقیقه کار از دست می‌رود؛ در حالت عادی هیچ.

## دستورهای روزمره روی VPS

```bash
systemctl status vpsmajani-sync        # وضعیت سرویس
journalctl -u vpsmajani-sync -f        # لاگ زنده
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/stats   # حجم snapshotها
du -sh /mnt/vpsmajani                  # فضای مصرفی
```

## نکات مهم

- **پورت ۸۷۸۷ را روی اینترنت عمومی باز نکن.** سرویس فقط از طریق Tailscale در دسترس است؛ در install.sh هم فقط `tailscale0` مجاز شده.
- توکن در `/etc/vpsmajani-sync.token` است و در `env` سرویس. اگر لو رفت، همان فایل را عوض کن و سکرت گیت‌هاب را آپدیت کن.
- snapshotها روی `/mnt/vpsmajani` هستند. اگر فضای ابری بلوکی داری، آن را روی همین مسیر mount کن تا داده به عمر VPS وابسته نباشد.
- سرویس، آخرین ۳ نسخه را نگه می‌دارد (`SNAP_KEEP`).
