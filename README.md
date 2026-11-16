# vpsmajani — سرور ابری ویندوز «نامحدود» روی GitHub Actions

یک ماشین ویندوزی روی رانرهای GitHub می‌سازد، RDP را باز می‌کند، با **Tailscale** به شبکهٔ
خصوصی شما وصل می‌شود و بعد **تا ابد خودش را تمدید می‌کند**: ۱۲ دقیقه مانده به مرگِ هر ماشین،
یک ماشین جایگزین با **همان IP و همان نام DNS** در صف می‌ایستد و به محض آزاد شدن، جای آن را
می‌گیرد.

فایل ورک‌فلو: [`.github/workflows/windows-rdp.yml`](.github/workflows/windows-rdp.yml)

---

## چه چیزی تا کجا «نامحدود» شد

| چیزی که قبلاً محدود بود | نسخهٔ قبل | الان | چطور |
|---|---|---|---|
| زمان روشن بودن | ۴۸ ساعت نوشته شده بود، ولی در عمل ۶ ساعت کشته می‌شد | **بی‌پایان** (زنجیرهٔ خودکار، ۶ ساعت در هر حلقه) | `workflow_dispatch` روی حلقهٔ بعدی + شمارندهٔ `chain_depth` |
| آدرس IP | هر بار یک IP تازه | **همیشه ثابت** | هویت نود Tailscale رمزنگاری‌شده در Actions cache ذخیره و بازیابی می‌شود |
| قطعی هنگام تمدید | — | **~۲ تا ۴ دقیقه در هر ۶ ساعت** | اول RDP و Tailscale بالا می‌آیند، کارهای سنگین بعداً در پس‌زمینه نصب می‌شوند |
| نشست‌های RDP | پیش‌فرض ویندوز | **بدون محدودتِ نشست** | `fSingleSessionPerUser=0`، `MaxInstanceCount=0xffffffff` |
| قطع شدن نشست | idle/disconnect پیش‌فرض | **هرگز** | `MaxIdleTime=0`، `MaxDisconnectionTime=0`، keep-alive هر ۶۰ ثانیه |
| سازگاری کلاینت | فقط NLA | NLA اختیاری | `UserAuthentication=0`، `SecurityLayer=1` |
| تعداد ماشین همزمان | ۱ | **تا ۲۰ ماشین موازی** | ورودی `instances` + `strategy.matrix` |
| قدرت ماشین | `windows-latest` | قابل انتخاب تا **۶۴ هسته** | ورودی `runner` |
| خواب/خاموشی صفحه | روشن | **خاموش** | `powercfg` + پلن Maximum Performance |
| مموری مجازی | پیش‌فرض | **System-managed (بدون سقف)** | `AutomaticManagedPagefile=true` |
| محدودیت پهنای باند | throttle پیش‌فرض ویندوز | **حذف شد** | `NetworkThrottlingIndex=0xffffffff`، `SystemResponsiveness=0`، `NonBestEffortLimit=0` |
| اتصالات TCP | پیش‌فرض | **بدون سقف عملی** | `TcpNumConnections=16777214`، `MaxUserPort=65534`، autotuning |
| ری‌استارت ناخواستهٔ آپدیت | ممکن | **غیرفعال** | سرویس‌ها و تسک‌های Windows Update خاموش |
| آنتی‌ویروس (کندی) | روشن | **Real-time خاموش** | `Set-MpPreference` + exclusion |
| مرورگر | IE-ESC فعال و غیرقابل استفاده | **باز** | IE Enhanced Security Configuration خاموش |
| راه دسترسی | فقط RDP | **RDP + SSH + (اختیاری) exit node** | OpenSSH Server + `--advertise-exit-node` |
| نرم‌افزار نصب‌شده | هیچ | Chrome, Firefox, 7zip, Git, Python, Node, VS Code, VLC | Chocolatey در پس‌زمینه، قابل تغییر با ورودی `packages` |
| رمز عبور | هاردکد شده در فایل | **secret یا تصادفی قوی برای هر ماشین** | `secrets.RDP_PASSWORD` یا تولید خودکار |
| تحمل خطا | هیچ | **self-heal + فیوز ۳ بار** | استپ `10 · Self-heal` با `if: failure()` |
| ترمز | فقط Cancel دستی | **۳ ترمز مستقل** | فایل `STOP-RDP`، متغیر `RDP_CHAIN_ENABLED`، رویداد `rdp-stop` |

---

## سقف‌هایی که با YAML عوض نمی‌شوند (صادقانه)

این‌ها محدودیت پلتفرم‌اند، نه باگ تنظیمات:

- **هر job روی رانرِ GitHub حداکثر ۶ ساعت (۳۶۰ دقیقه).** مقدارِ بیشتر در `timeout-minutes`
  بی‌اثر است و job دقیقاً در ساعت ششم کشته می‌شود. «نامحدود» اینجا یعنی **زنجیرهٔ بی‌پایانِ
  ماشین‌های ۶ ساعته با آدرس ثابت**، نه یک ماشین جاودان.
- **job همزمان:** Free = ۲۰، Pro = ۴۰، Team = ۶۰ (ورودی `instances` تا ۲۰slot را پوشش می‌دهد).
- **دقیقهٔ رایگان:** برای ریپوی **public** رایگان و بدون سقف است (حالت شما). برای ریپوی private
  ۲۰۰۰ دقیقه در ماه، و ویندوز ضریب ۲ دارد.
- **ماشین هر بار نو است:** دیسک، RAM و هر چیزی که روی درایو ذخیره کرده‌اید با پایان job از بین
  می‌رود. تنها چیزی که بین حلقه‌ها منتقل می‌شود، هویت Tailscale است (برای ثابت ماندن IP).
  برای ذخیرهٔ واقعی داده، به Google Drive / OneDrive / یک repo دیگر push کنید.
- **GPU وجود ندارد** — رانرهای ویندوز GitHub GPU ندارند.

### یک ماشین جاودان می‌خواهید؟ → self-hosted

اگر یک کامپیوتر/سرور همیشه‌روشن دارید، همان ورک‌فلو را با ورودی `runner = self-hosted` و
`duration = 4320` اجرا کنید: **۷۲ ساعت در یک job**، بدون مصرف دقیقهٔ GitHub، و بدون هیچ
hand-over‌ای. این تنها راهِ یک ماشینِ واقعاً یک‌تکه و بی‌قطعی است.

---

## پیش‌نیازها (یک بار، ۵ دقیقه)

**۱. فایل ورک‌فلو باید روی برنچ پیش‌فرض (`main`) باشد.**
`workflow_dispatch` فقط برای ورک‌فلویی کار می‌کند که روی برنچ پیش‌فرض وجود دارد؛ زنجیرهٔ
تمدید خودکار هم به همین دلیل فقط از `main` قابل dispatch است. پس این برنچ را merge کنید.

**۲. کلید Tailscale بسازید** — از <https://login.tailscale.com/admin/settings/keys>:

| گزینه | مقدار | چرا |
|---|---|---|
| Reusable | **روشن** | هر حلقهٔ زنجیره یک ماشین تازه است |
| Ephemeral | **خاموش** | اگر روشن باشد، نود با خاموش شدن ماشین پاک می‌شود و IP عوض می‌شود |
| Expiration | **بدون انقضا** | وگرنه وسط کار کلید می‌سوزد |
| Pre-approved tags | اختیاری `tag:rdp` | برای exit node و سیاست‌های ACL |

**۳. Secretها** — در `Settings → Secrets and variables → Actions`:

| نام | لازم؟ | کارکرد |
|---|---|---|
| `TAILSCALE_AUTHKEY` | **بله** | کلید بالا؛ همچنین کلید رمزنگاری هویت ذخیره‌شده |
| `RDP_PASSWORD` | نه | رمز ثابت؛ اگر باشد در لاگ **mask** می‌شود (امن‌تر) |
| `TAILSCALE_IDENTITY_KEY` | نه | اگر خواستید کلید رمزنگاری هویت جدا از authkey باشد |

> اگر `RDP_PASSWORD` را نگذارید، برای هر ماشین یک رمز تصادفی ۲۲ کاراکتری ساخته می‌شود و در
> لاگ و Job summary چاپ می‌شود (راحت‌تر، ولی چون ریپوی شما **public** است، لاگ‌ها هم عمومی‌اند).

---

## اجرا

از تب **Actions → Windows Cloud RDP · Unlimited → Run workflow**، یا با `gh`:

```bash
# یک ماشین، ۶ ساعت، تمدید خودکار بی‌پایان (همه‌چیز پیش‌فرض)
gh workflow run windows-rdp.yml

# سه ماشین موازی
gh workflow run windows-rdp.yml -f instances='[1,2,3]'

# ماشین قوی‌تر + بدون نرم‌افزار اضافه + ۲۴ حلقه (≈ ۶ روز) و بس
gh workflow run windows-rdp.yml -f runner=windows-latest-16-cores -f packages=none -f max_chain=24

# بدون تمدید خودکار، فقط یک ماشین ۶ ساعته
gh workflow run windows-rdp.yml -f renew=false

# از راه دور، بدون ورود به سایت
gh api repos/mahdiyar1388mm1-design/vpsmajani/dispatches -f event_type=rdp-start
```

---

## اتصال

اطلاعات در **لاگ استپ `07 · Publish connection details`** و در **Job summary** چاپ می‌شود:

```
================================================================
    >>>   U N L I M I T E D   R D P   I S   L I V E   <<<
================================================================
  Tailscale IP : 100.x.y.z
  MagicDNS     : github-rdp-server.tail1234.ts.net
  Username     : NvDAdmin   (also runneradmin)
  Password     : Xk9...
  SSH          : ssh NvDAdmin@100.x.y.z
  Alive until  : 2026-11-16 21:40 UTC
  Auto-renew   : true (link #1 of unlimited)
  >> mstsc /v:100.x.y.z
================================================================
```

- **ویندوز:** `mstsc /v:100.x.y.z` — همین آدرس را pin کنید، بعد از هر تمدید همان است.
- **موبایل/لینوکس:** کلاینت Tailscale را نصب کنید، بعد با Microsoft Remote Desktop به همان IP.
- **SSH:** `ssh NvDAdmin@100.x.y.z` (شل پیش‌فرض PowerShell است).
- روی خود ماشین هم فایل `C:\RDP-CREDENTIALS.txt` هست.

---

## ورودی‌ها

| ورودی | پیش‌فرض | توضیح |
|---|---|---|
| `instances` | `[1]` | چند ماشین موازی؛ مثلاً `[1,2,3,4]` = چهار ماشین با چهار IP ثابت جداگانه |
| `runner` | `windows-latest` | `windows-2025`، `windows-latest-8-cores` … `64-cores` (باید در Settings فعال باشند)، یا `self-hosted` |
| `duration` | `360` | دقیقه برای هر ماشین؛ سقف رانر GitHub = ۳۶۰، سقف self-hosted = ۴۳۲۰ |
| `handover` | `12` | چند دقیقه مانده به پایان، ماشین جایگزین در صف بایستد (و در صورت خطا، هر دقیقه دوباره تلاش می‌کند) |
| `renew` | `true` | زنجیرهٔ بی‌پایان |
| `max_chain` | `0` | حداکثر تعداد حلقه؛ `0` = نامحدود |
| `hostname` | `github-rdp-server` | نام نود در Tailscale (بین حلقه‌ها ثابت می‌ماند) |
| `packages` | کروم، فایرفاکس، 7zip، git، python، nodejs، vscode، vlc | با `none` کاملاً رد می‌شود |
| `ssh` | `true` | سرور OpenSSH روی پورت ۲۲ |
| `exit_node` | `false` | ماشین را exit node می‌کند؛ بعد باید در کنسول Tailscale تأییدش کنید |
| `reset_runneradmin` | `true` | اکانت داخلی رانر هم همان رمز را می‌گیرد |
| `persist_identity` | `true` | ثابت نگه داشتن IP بین حلقه‌ها (رمزنگاری‌شده در cache) |
| `tailscale_args` | خالی | آرگومان خام اضافه برای `tailscale up` |
| `chain_depth`, `chain_heals` | `0` | **داخلی** — خود زنجیره پر می‌کند، دست نزنید |

---

## زنجیرهٔ تمدید خودکار چطور کار می‌کند

```
دقیقهٔ 0        ماشین #1 بالا می‌آید ── RDP + Tailscale در ~۲ دقیقه آماده
دقیقهٔ ۲ تا ۶۰  تنظیمات سیستم و نصب نرم‌افزارها در پس‌زمینه (task با کاربر SYSTEM)
دقیقهٔ ۳۴۸      لینک #2 dispatch می‌شود ── پشتِ concurrency در صف می‌ایستد
دقیقهٔ ۳۶۰      ماشین #1 خاموش می‌شود ── همان لحظه ماشین #2 boot می‌شود
                هویت رمزنگاری‌شده از cache برمی‌گردد ── همان IP، همان نام DNS
دقیقهٔ ~۳۶۳     ماشین #2 در دسترس است  ── و این تا ابد تکرار می‌شود
```

- `concurrency: rdp-slot-N` باعث می‌شود دو ماشین هیچ‌وقت هم‌زمان از یک هویت Tailscale
  استفاده نکنند (این کار IP را خراب می‌کند).
- در حالت چند ماشینی (`instances='[1,2,3]'`)، فقط **slot اول** حلقهٔ بعدی را می‌سازد و آن
  حلقه همهٔ slot‌ها را با هم برمی‌گرداند؛ پس هر ماشین IP ثابتِ خودش را دارد.
- اگر dispatch به هر دلیلی شکست بخورد، تا آخرین دقیقه هر ۶۰ ثانیه دوباره تلاش می‌شود.
- اگر job **کرش** کند، استپ `10 · Self-heal` یک ماشین جایگزین می‌فرستد تا زنجیره قطع نشود.
  **فیوز:** اگر ماشین قبل از وصل شدن به Tailscale بمیرد، زنجیره ادامه پیدا نمی‌کند (وگرنه یک
  حلقهٔ خراب بی‌نهایت دقیقه می‌سوزاند)؛ و پشت‌سرهم حداکثر ۳ self-heal مجاز است.

---

## ترمزها

| روش | اثر |
|---|---|
| ساخت فایل `STOP-RDP` در ریشهٔ ریپو (روی `main`) | حلقهٔ بعدی ساخته نمی‌شود؛ ماشین فعلی تا پایان ۶ ساعت زنده می‌ماند |
| متغیر `RDP_CHAIN_ENABLED = false` در `Settings → Secrets and variables → Actions → Variables` | دقیقاً مثل بالا، بدون commit |
| `gh api repos/mahdiyar1388mm1-design/vpsmajani/dispatches -f event_type=rdp-stop` | **فوری:** همهٔ run‌های در حال اجرا و در صف کنسل می‌شوند |
| دکمهٔ Cancel workflow در تب Actions | همان ماشین را فوراً می‌کشد |

---

## امنیت (حتماً بخوانید)

1. **ریپوی شما public است** ⇒ لاگ‌های Actions هم public‌اند. اگر `RDP_PASSWORD` را ست نکنید،
   رمز ماشین در لاگ عمومی دیده می‌شود. دسترسی واقعی فقط از طریق Tailscale ممکن است، ولی
   توصیهٔ جدی: یا `RDP_PASSWORD` بگذارید (تا mask شود)، یا ریپو را private کنید.
2. هویت نود Tailscale در Actions cache ذخیره می‌شود. در ریپوی public، یک PR از fork می‌تواند
   cache را بخواند — به همین دلیل آن را با کلید مشتق‌شده از secret **AES-256 رمزنگاری** می‌کنیم؛
   بدون secret، آن فایل فقط نویز است.
3. NLA خاموش شده تا کلاینت‌های موبایل/قدیمی وصل شوند؛ در عوض یک لایهٔ احراز هویت کمتر است.
   اگر فقط از کلاینت‌های جدید استفاده می‌کنید، `UserAuthentication=1` امن‌تر است.
4. Defender real-time و Windows Update خاموش می‌شوند: ماشین سریع‌تر است، ولی به‌روز نمی‌شود.
   این ماشین هر ۶ ساعت از نو ساخته می‌شود، عملاً همیشه با ایمیج تازه است.
5. `exit_node=true` یعنی هر ترافیکی که از آن عبور دهید با IP این ماشین بیرون می‌رود؛ فقط در
   صورت نیاز روشنش کنید و در کنسول Tailscale تأییدش کنید.

---

## عیب‌یابی

| مشکل | علت / راه‌حل |
|---|---|
| `Run workflow` دیده نمی‌شود | فایل ورک‌فلو روی `main` نیست — merge کنید |
| `HTTP 403: Resource not accessible` هنگام تمدید | `permissions: actions: write` حذف شده؛ یا از PAT استفاده شده |
| `HTTP 404` هنگام تمدید | ورک‌فلو روی برنچ پیش‌فرض نیست |
| IP هر بار عوض می‌شود | authkey **ephemeral** است (خاموشش کنید)، یا `persist_identity=false` است، یا اولین اجرا را از برنچی غیر از `main` زده‌اید (cache به برنچ‌ها مقید است) |
| `tailscale up` شکست می‌خورد | Secret `TAILSCALE_AUTHKEY` نیست یا منقضی شده؛ هویت ذخیره‌شده هم سوخته → خودکار از نو ثبت می‌شود |
| RDP وصل می‌شود ولی صفحه سیاه است | یک دقیقه صبر کنید؛ تنظیمات پس‌زمینه هنوز در حال اجراست (`C:\unlimited-setup.log`) |
| ماشین زودتر از ۶ ساعت مرد | `duration` را کمتر از ۳۶۰ گذاشته‌اید، یا GitHub به خاطر نقص قوانین run را کنسل کرده |
| `no runners available` | لیبل بزرگ‌تر (`-16-cores`) در ریپو فعال نیست؛ `Settings → Actions → Runners` |
| می‌خواهم داده‌هایم بماند | روی ماشین هیچ‌چیز نمی‌ماند؛ به Drive/OneDrive sync کنید یا `git push` بزنید |

---

## ابزار توسعه

`tools/lint_workflow.py` بدون نیاز به `actionlint` یا PowerShell، ساختار ورک‌فلو را بررسی
می‌کند: صحت YAML، متوازن بودن `${{ }}`، context‌های مجاز، بسته شدن here-stringها در ستون صفر،
و متوازن بودن براکت‌ها در هر دو اسکریپتِ تو‌در‌تو.

```bash
python3 tools/lint_workflow.py
```
