# VoYah - جدولة المهام الموزعة لنظام الكوكبيت الذكي

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![Build: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

[English](README_en.md) &nbsp;.&nbsp; [Chinese](README.md) &nbsp;.&nbsp; [Japanese](README_ja.md) &nbsp;.&nbsp; [Russian](README_ru.md) &nbsp;.&nbsp; [Arabic](README_ar.md)

**جدولة مهام موزعة عالية الموثوقية تعمل بالحدث لنظام الكوكبيت الذكي.**
مُنشأ بـ epoll + timerfd + socketpair - بدون مكتبات خارجية.

</div>

---

## الفهرس

- [المميزات](#المميزات)
- [البنية](#البنية)
- [البدء السريع](#البدء-السريع)
- [أنواع المهام](#أنواع-المهام)
- [التحكم التفاعلي](#التحكم-التفاعلي)
- [التحكم بالإشارات](#التحكم-بالإشارات)
- [مجموعة الاختبارات](#مجموعة-الاختبارات)
- [البناء والتشغيل](#البناء-والتشغيل)
- [هيكل المشروع](#هيكل-المشروع)
- [قرارات التصميم](#قرارات-التصميم)
- [الأداء](#الأداء)
- [Roadmap](#roadmap)
- [الترخيص](#الترخيص)

---

## المميزات

| الميزة | التنفيذ | الفائدة |
|--------|---------|---------|
| **عزل العمليات** | fork() + socketpair | تعطل Worker واحد لا يؤثر على النظام |
| **I/O multiplexing بـ O(1)** | وضع epoll LT | latency منخفض ومستقر تحت الحمل العالي |
| **مؤقتات بدقة النانوثانية** | timerfd + itimerspec | دورات إرسال/تقارير دقيقة |
| **IPC بدون نسخ** | socketpair SOCK_DGRAM | اتصال فعّال بين Manager و Worker |
| **إيقاف سلس** | SIGINT + رسالة 'X' | لا عمليات زومبي، لا فقدان مهام |
| **توسع ديناميكي** | +/- أثناء التشغيل أو SIGUSR1/SIGUSR2 | ضبط حجم الـ pool مباشرة |
| **إصلاح ذاتي عند الأعطال** | Heartbeat watchdog | استبدال Workers المتعطلة وإنقاذ المهام المعلقة |
| **إعادة المحاولة عند انتهاء المهلة** | 5s مهلة / حتى مرتين | عدم فقدان المهام أثناء اضطرابات الشبكة |
| **سجل منظم** | JSONL مع طوابع زمنية | للتحليل لاحقاً |

---

## البنية

```
+-----------------------------------------------------------------------+
|                       Manager (parent process)                          |
|  +---------------------------------------------------------------+    |
|  |                     EventLoop (epoll)                           |    |
|  |   epoll_wait() ------------------------------------------->  |    |
|  |   +-----------+ +-----------+ +-----------+ +--------+        |    |
|  |   |timerfd    | |timerfd    | |timerfd    | | stdin  |        |    |
|  |   |1s dispatch| |2s heartbeat| |5s report  | |(+ / -) |        |    |
|  |   +-----+-----+ +-----+-----+ +-----+-----+ +---+----+        |    |
|  +--------+-----------+-----------+-----------+------+----+--------+    |
+----------+-----------+-----------+-----------+------+----+---------------+
            |           |           |           |      |
            V           V           V           V      V
      +---------+ +---------+ +---------+
      | Worker 1| | Worker 2| | Worker N |
      | (fork)  | | (fork)  | | (fork)  |
      |recv_task| |recv_task| |recv_task|
      | +-sleep | | +-sleep | | +-sleep |
      | +-done  | | +-done  | | +-done  |
      | +-pong  | | +-pong  | | +-pong  |
      +---------+ +---------+ +---------+
```

- **Manager**: حلقة أحداث واحدة، تملك دورة حياة جميع الـ FD، تتعامل مع الإرسال والـ watchdog والتقارير.
- **Worker**: وحدة تنفيذ بحتة - استقبال، معالجة، إرسال pong. لا منطق جدولة.
- **IPC**: socketpair واحد لكل Worker، اتصال ثنائي الاتجاه كامل، غير محظور على الطرفين.

---

## البدء السريع

```bash
make                    # البناء
./bin/scheduler --help  # عرض المساعدة
./bin/scheduler 5       # تشغيل بـ 5 Workers (3 <= N <= 10)
make test               # تشغيل جميع الاختبارات
make clean              # تنظيف المخرجات
```

---

## أنواع المهام

| النوع | وقت المعالجة | سيناريو الكوكبيت |
|------|-------------|-----------------|
| **A** | 100 مللي ثانية | استيعاب بيانات الحساسات |
| **B** | 200 مللي ثانية | معالجة تدفق الوسائط |
| **C** | 300 مللي ثانية | حساب مسار الملاحة |

---

## التحكم التفاعلي

| المدخل | الإجراء |
|--------|---------|
| `+` | إضافة 1 Worker (الحد الأقصى 10) |
| `-` | إزالة 1 Worker (الحد الأدنى 1) |
| `s`/`S` | طباعة الإحصائيات فوراً |
| `i`/`I` | طباعة معلومات تفصيلية عن Workers |
| `p`/`P` | طباعة متتبع المهام المعلقة |
| `q`/`Q` | إيقاف سلس |
| `Ctrl+C` | إيقاف سلس |

---

## التحكم بالإشارات

```bash
kill -SIGUSR1 $(pidof scheduler)   # إضافة Worker
kill -SIGUSR2 $(pidof scheduler)   # إزالة Worker
kill -SIGINT  $(pidof scheduler)   # إيقاف سلس
```

---

## مجموعة الاختبارات

```bash
make test       # تشغيل جميع الاختبارات التسعة
make test-quick # اختبارات دخانية فقط
```

| الاختبار | يتحقق من |
|---------|---------|
| `test_boundary.sh` | N=3/10 نجاح؛ N=2/11 رفض |
| `test_stress.sh` | Workers kill -9 -> إصلاح ذاتي |
| `test_dynamic.sh` | +/- التوسع الديناميكي |
| `test_signal.sh` | تحكم SIGUSR1/SIGUSR2 |
| `test_timeout_retry.sh` | منطق المهلة وإعادة المحاولة |
| `test_perf.sh` | مقاييس الإنتاجية والـ latency |
| `test_concurrent.sh` | صحة التزامن |
| `test_graceful.sh` | إيقاف سلس مع بروتوكول X |
| `test_jsonl.sh` | سجلات JSONL المنظمة |

---

## البناء والتشغيل

### المتطلبات

| التبعية | الإصدار |
|---------|---------|
| نواة Linux | 4.x+ |
| GCC أو Clang | 7+ (C++17) |
| GNU Make | أي إصدار حديث |

### الأوامر

```bash
make              # البناء -> ./bin/scheduler
make test         # جميع الاختبارات التسعة
make test-quick   # اختبارات الحدود والإيقاف السلس فقط
make install      # التثبيت في /usr/local/bin
make clean        # حذف ./bin و *.jsonl
make help         # عرض جميع الأهداف
```

### رموز الخروج

| الرمز | المعنى |
|-------|-------|
| `0` | نجاح |
| `64` | خطأ في استخدام CLI |
| `70` | خطأ في وقت التشغيل (فشل fork/socketpair/epoll_create) |

---

## هيكل المشروع

```
VoYah_project/
|-- CMakeLists.txt              # البناء باستخدام CMake (اختياري)
|-- Makefile                    # نقطة دخول سريعة للبناء
|-- .editorconfig              # إعدادات المحرر
|-- .gitignore                 # قواعد تجاهل Git
|-- LICENSE                    # ترخيص MIT
|-- AUTHORS                    # قائمة المؤلفين
|-- CONTRIBUTING.md            # دليل المساهمة
|-- CODE_OF_CONDUCT.md         # مدونة السلوك المجتمعي
|-- CHANGELOG.md              # سجل تغييرات الإصدارات
|-- src/                       # الكود المصدري
|   |-- CMakeLists.txt
|   +-- scheduler.cpp           # التنفيذ الكامل (~1000 سطر)
|-- include/                   # ملفات الرأس العامة
|   +-- voyah/
|       +-- version.h          # تعريفات إصدارات الماكرو
|-- docs/                      # التوثيق
|   |-- README.md             # الصفحة الرئيسية (الصينية)
|   |-- README_en.md          # النسخة الإنجليزية
|   |-- README_ja.md          # النسخة اليابانية
|   |-- README_ru.md          # النسخة الروسية
|   |-- README_ar.md          # هذا الملف (العربية)
|   +-- DESIGN.md              # وثيقة تصميم النظام
|-- test/                      # 9 نصوص اختبار
|-- examples/                   # أمثلة الاستخدام
|   +-- run_demo.sh           # سكريبت تشغيل العرض
+-- .github/
    |-- workflows/ci.yml        # GitHub Actions CI/CD
    |-- ISSUE_TEMPLATE/          # قوالب المسائل
    +-- PULL_REQUEST_TEMPLATE.md # قالب PR
```

---

## قرارات التصميم

### لماذا epoll وليس select / poll؟

| المعيار | select | poll | epoll |
|---------|--------|------|-------|
| حد عدد الـ FD | FD_SETSIZE (1024) | بلا حد | بلا حد |
| التعقيد الزمني | O(n) فحص الكل | O(n) فحص الكل | **O(1) FD الجاهزة فقط** |
| الذاكرة لكل استدعاء | عالية (نسخ in/out) | عالية (نسخ in/out) | منخفضة (تسجيل مرة واحدة) |
| ملاءمة للكوكبيت | لا | لا | **نعم - الوقت الحقيقي، latency بالميكروثانية** |

### لماذا العمليات المتعددة بدلاً من الخيوط المتعددة؟

- **الموثوقية**: تعطل Worker واحد معزول، Manager يستمر.
- **بدون أقفال**: حدود العملية تقضي على سباقات البيانات جوهرياً.
- **fork الحديث**: Copy-on-write يجعل fork شبه مجاني للأحمال القراءة فقط.

### لماذا الاستدعاءات النظامية الخام بدلاً من libevent / libuv؟

- تُظهر فهماً عميقاً لأساسيات Linux I/O.
- بدون مكتبات خارجية - GNU/Linux خالص.
- epoll + timerfd + socketpair تغطي كل احتياجات multiplex وtiming و IPC.

---

## الأداء

| المقياس | القيمة |
|---------|-------|
| latency الإرسال (1 Worker، 1 مهمة) | < 1 مللي ثانية |
| وقت إجابة epoll_wait | < 100 ميكروثانية |
| دقة المؤقت (timerfd) | نانوثانية (itimerspec) |
| إعداد Worker (fork + socketpair) | < 5 مللي ثانية |
| الإيقاف السلس (N Workers) | < 100 مللي ثانية + N x وقت المعالجة |
| أقصى عدد Workers متزامنين | 10 (قابل للضبط) |

---

## Roadmap

- [ ] أوزان مهام قابلة للضبط وحدود حمل لكل Worker
- [ ] طابور أولويات للمهام العاجلة في الكوكبيت
- [ ] نقل بدون نسخ عبر الذاكرة المشتركة (mmap)
- [ ] واجهة HTTP/MQTT لحقن المهام عن بُعد
- [ ] وضع HA متعدد Managers مع انتخاب القائد
- [ ] لوحة ويب للتصور في الوقت الحقيقي
- [ ] طبقة توافق Windows WSL2

---

## الترخيص

ترخيص MIT - انظر [LICENSE](../LICENSE).
