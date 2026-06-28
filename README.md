<div align="center">

# X-NET Panel

**پنل مدیریت VPN / Proxy و تونل SSH — با هستهٔ Sing-box و معماری چندنودی**

[![Sing-box](https://img.shields.io/badge/engine-sing--box-10b981)](https://sing-box.sagernet.org)
[![Backend](https://img.shields.io/badge/backend-Go-00ADD8)](https://go.dev)
[![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Vite-61dafb)](https://react.dev)
[![License](https://img.shields.io/badge/license-X--NET-yellow)](../LICENSE)

🌐 **فارسی** · [English](README.en.md) · [Русский](README.ru.md) · [中文](README.zh.md)

</div>

---

<div dir="rtl">

## معرفی

پروزه **X-NET** پنلی برای ساخت و مدیریت سرویس‌های **VPN/Proxy** و **اکانت‌های SSH** است؛ از طریق آن کاربران (اشتراک‌ها) را می‌سازید، ترافیک و انقضای هرکدام را کنترل می‌کنید و لینک اشتراک تحویل می‌دهید.

- پردازش ترافیک با هستهٔ **Sing-box**
- امکان ساخت **اکانت SSH** با پروتکل‌های متنوع: SSH-over-WebSocket، Stunnel/TLS، SlowDNS، Dropbear و BadVPN/UDPGW
- **ایزوله‌سازی دسترسی:** هر اکانت SSH فقط به پورت/پروتکل خودش دسترسی دارد
- مدیریت **چند سرور** از یک رابط واحد: یک سرور «پنل» و بقیه «نود»

---

## نصب

### پیش‌نیازها

- سرور لینوکس (Ubuntu / Debian توصیه می‌شود)، معماری `amd64`
- دسترسی `root`

### نصب پنل

```bash
apt update
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
```

نصب‌کننده ۳ نسخهٔ آخر را در یک منو نشان می‌دهد؛ برای نصب مستقیم یک نسخهٔ مشخص:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh) v1.2.3
```

در نصب اولیه، پورت پنل و اطلاعات ادمین پرسیده می‌شود، سرویس systemd ساخته می‌شود، هستهٔ sing-box و زیرسیستم‌های SSH نصب می‌شوند و پورت در فایروال باز می‌شود. در اجرای مجدد (بروزرسانی)، فایل `.env` و دیتابیس حفظ می‌شوند.

### نصب نود (Agent)

همان دستور نصب را روی سرور نود اجرا کنید و در پرسش نقش، مقدار `agent` را انتخاب کنید. سپس در پنل وارد **سرورها و نودها → Register Node** شوید؛ کلیدهای تولیدشده را در `/opt/xnet/.env` نود قرار دهید و سرویس را restart کنید:

```bash
nano /opt/xnet/.env
#   NODE_ROLE=agent
#   NODE_API_KEY=xnetnode_...
#   NODE_SECRET_KEY=...
systemctl restart xnet
```

### مدیریت سرویس

```bash
systemctl status xnet      # وضعیت سرویس
journalctl -u xnet -f      # لاگ زنده
systemctl restart xnet     # اجرای دوباره
```

> **امنیت:** آدرس `http://IP:PORT` رمزنگاری‌شده نیست؛ برای محیط واقعی پنل را پشت دامنه + HTTPS قرار دهید.

---

## پروتکل‌ها

### پروتکل‌های هسته (Sing-box)

`VLESS` · `VMess` · `Trojan` · `Shadowsocks` · `SOCKS` · `HTTP` · `TUIC` · `Hysteria2` · `WireGuard` · `Mixed` · `TUN` · `ShadowTLS` · `NaiveProxy`

### ترابری‌ها (Transports)

`TCP` · `WebSocket` · `gRPC` · `HTTP/2` · `HTTPUpgrade` · `QUIC`

### امنیت / TLS

`Plain` · `TLS` · `Reality`

### SSH

`SSH-over-WebSocket` · `Stunnel/TLS` · `SlowDNS` · `Dropbear` · `BadVPN/UDPGW`

## امکانات

### مدیریت اینباندها
ساخت، ویرایش، کلون، فعال/غیرفعال‌سازی و استقرار روی چند نود
### مدیریت اشتراک‌ها
لینک اشتراک، QR Code، سقف حجم، تاریخ انقضا، سقف دستگاه همزمان، تمدید و ریست ترافیک
### اکانت‌های SSH
ساخت کاربر سیستمی، محدودسازی ترافیک و تعداد ورود همزمان
### چندنودی
نقش‌های panel/agent، همگام‌سازی خودکار، و **تک‌نود فعال (Follow-Me)** با جابجایی نود از لینک اشتراک
### امنیت
ورود با JWT، احراز هویت دومرحله‌ای (TOTP)، نقش‌های دسترسی (ادمین/اپراتور/نماینده) و امضای HMAC بین پنل و نود
### دامنه و گواهی
بررسی واقعی DNS، صدور/تمدید گواهی TLS (Let's Encrypt)
### مسیریابی و شبکه
قوانین Routing (GeoSite/GeoIP، AdBlock)، پیکربندی DNS و کنترل تراکم TCP BBR
### مانیتورینگ
داشبورد، تحلیل ترافیک، لاگ زنده، پشتیبان‌گیری/بازیابی دیتابیس
### API
توکن Bearer، مستندات و playground، و فایروال whitelist آی‌پی
### رابط کاربری
چندزبانه (فارسی/انگلیسی/روسی/چینی)، تم روشن و تاریک، بروزرسانی خودکار صفحات

## مجوز

این پروژه تحت **X-NET Software License (Version 1.0)** — یک مجوز اختصاصی — منتشر شده است. متن کامل در فایل [`LICENSE`](../LICENSE).

| وضعیت | توضیح |
|---|---|
| ✅ مجاز | استفاده از توزیع رسمی کامپایل‌شده برای مقاصد شخصی و تجاری، نصب روی هر تعداد سرور |
| 🔒 اختصاصی | سورس‌کد — بدون حق دسترسی، تغییر، انتشار یا مهندسی معکوس |
| ❌ ممنوع | حذف/تغییر کپی‌رایت، توزیع نسخهٔ تغییریافته، استفاده از نام X-NET بدون اجازهٔ کتبی |
| ⚠️ بدون ضمانت | نرم‌افزار «همان‌گونه که هست» ارائه می‌شود؛ مسئولیت رعایت قوانین بر عهدهٔ کاربر است |

> **Copyright (c) 2026 X-NET. All Rights Reserved.**

</div>
