# MuRF Pedal — клон Behringer BM-15M / Moog MF-105M на Raspberry Pi

Самодельная аналого-цифровая педаль на базе Raspberry Pi 3B и SuperCollider, с управлением через веб-интерфейс по Wi-Fi. Первая реализация — клон Behringer BM-15M MURF Box (он же клон оригинального Moog Moogerfooger MF-105M MIDI MuRF). Архитектура заложена с прицелом на смену пресетов/эффектов в будущем.

## Содержание

- [Общая архитектура](#общая-архитектура)
- [Железо](#железо)
- [Софт](#софт)
- [Структура проекта](#структура-проекта)
- [Формат пресетов](#формат-пресетов)
- [OSC namespace](#osc-namespace)
- [WebSocket-протокол](#websocket-протокол)
- [Нюансы и риски](#нюансы-и-риски)
- [Roadmap](#roadmap)

## Общая архитектура

```
┌─────────────────────────────────────────────┐
│  Мобилка (браузер)                            │
│  HTML/CSS/Vanilla JS — фейдеры, паттерны      │
└───────────────────┬───────────────────────────┘
                     │ Wi-Fi (RPi как AP: hostapd+dnsmasq)
                     │ WebSocket
┌────────────────────▼──────────────────────────┐
│  Node.js / Express  (сервер на RPi)            │
│  - отдаёт статику (index.html, app.js, css)    │
│  - WebSocket-сервер                            │
│  - транслирует команды в OSC                   │
└───────────────────┬───────────────────────────-┘
                     │ OSC (localhost:57121)
┌────────────────────▼──────────────────────────┐
│  sclang (логика)                                │
│  - OSC-listener (OSCdef)                       │
│  - pattern-движок (Routine/Tdef)                │
│  - загрузка/хранение пресетов (JSON на диске)  │
│  - реестр SynthDef'ов для будущих эффектов     │
└───────────────────┬───────────────────────────-┘
                     │ OSC (localhost:57110)
┌────────────────────▼──────────────────────────┐
│  scsynth (DSP, RT-приоритет, отдельное ядро)   │
│  - SynthDef \murf: 8×BPF + envelope per band   │
│  - I/O через ALSA → DA7212 codec               │
└─────────────────────────────────────────────────┘
                     │ I2S
┌────────────────────▼──────────────────────────┐
│  DA7212 Audio Board (line-in/line-out)         │
└─────────────────────────────────────────────────┘
                     │ аналоговый вход
┌────────────────────▼──────────────────────────┐
│  Входная цепочка (буфер + делитель)            │
│  Instrument → JFET buffer → DC-block →         │
│  → voltage divider → AUX-in                    │
└─────────────────────────────────────────────────┘
```

## Железо

| Компонент | Что | Зачем |
|---|---|---|
| Материнка | Raspberry Pi 3B | DSP-хост |
| Аудиокодек | Waveshare DA7212 Audio Board (A) | full-duplex I2S, line-in/line-out, $14, без переделок платы |
| Входной буфер | JFET-каскад (например 2N5457) | согласование высокого выходного импеданса гитары/синта |
| Входной делитель | резистивный аттенюатор (номиналы — после замеров входного импеданса AUX DA7212) | защита ADC от клиппинга на инструментальном уровне сигнала |
| DC-блок | конденсатор на входе | защита ADC от DC-смещения |
| Питание | стабильный БП ≥2.5A | избежать undervoltage throttling при одновременной нагрузке Wi-Fi AP + аудио |

### Почему не встроенный 3.5mm джек Pi
PWM-выход без отдельного DAC, ограничение ~11 бит/48kHz, и главное — отсутствие входа в принципе. Не подходит ни по качеству, ни по функциям.

### Почему DA7212, а не WM8960 / PiFi DAC+
- PiFi DAC+ (PCM5122) — только выход, нет ADC.
- WM8960 HAT — есть free пины LINPUT2/RINPUT3 на чипе, но требуют пайки + патч device tree overlay.
- DA7212 Audio Board (A) — AUX-вход из коробки, без вмешательства в плату, $14, full-duplex на одном чипе/clock domain.

## Софт

### OS
Raspberry Pi OS Lite (64-bit), headless, без графической оболочки.

### Realtime-настройка
```bash
sudo usermod -aG audio pi
```
`/etc/security/limits.d/audio.conf`:
```
@audio - rtprio 95
@audio - memlock unlimited
```
`/boot/firmware/cmdline.txt` — добавить `isolcpus=3`, отдать одно ядро целиком под scsynth.

### Аудио-стек
Без JACK (программного) — scsynth работает напрямую через ALSA. Один аудио-девайс, минимум слоёв, минимум latency overhead. JACK можно добавить позже, если появится необходимость роутинга между несколькими процессами.

`/boot/firmware/config.txt`:
```
dtoverlay=da7212-audio
dtparam=audio=off
```

### Пакеты
```bash
sudo apt install supercollider-server supercollider-language \
    nodejs npm hostapd dnsmasq
```
(не ставить мета-пакет `supercollider` целиком — тащит Qt/GUI, не нужный на headless-системе)

### Сеть
Pi — точка доступа Wi-Fi (`hostapd` + `dnsmasq`), мобилка подключается к ней напрямую.

### Процессы и автозапуск
Три systemd-юнита с зависимостями (scsynth → sclang → webserver), автоперезапуск при крэше:
- `scsynth.service`
- `sclang.service`
- `webserver.service`

## Структура проекта

```
/home/pi/murf/
├── sc/
│   ├── main.scd          # запуск scsynth + OSCdef-роутинг
│   ├── synthdefs/
│   │   └── murf.scd      # SynthDef \murf — 8×BPF + envelope per band
│   └── presets/
│       └── murf_default.json
├── web/
│   ├── server.js         # Express + WS + OSC-relay
│   └── public/
│       ├── index.html
│       ├── app.js
│       └── style.css
└── systemd/
    ├── scsynth.service
    ├── sclang.service
    └── webserver.service
```

## Формат пресетов

Пресет = JSON-файл, описывающий какой SynthDef грузить и с какими параметрами/паттерном:

```json
{
  "name": "murf_default",
  "synthdef": "murf",
  "params": {
    "rate": 2.0,
    "drive": 0.3,
    "mix": 0.8
  },
  "pattern": [
    [1,0,0,0,1,0,0,0],
    [0,1,0,0,0,1,0,0],
    [0,0,1,0,0,0,1,0]
  ]
}
```

Смена эффекта в будущем = новый `synthdef` + свой набор `params`/`pattern`. Web-UI и OSC-роутинг не меняются.

## OSC namespace

| Адрес | Назначение |
|---|---|
| `/murf/band/<n>/level` | громкость n-го фильтра (0–7) |
| `/murf/pattern/load` | загрузить паттерн |
| `/murf/param/<name>` | изменить параметр (rate, drive, mix...) |
| `/synth/switch` | переключить активный SynthDef (под будущие эффекты) |
| `/preset/load` | загрузить пресет по имени |

## WebSocket-протокол

Простой JSON-формат сообщений от клиента к серверу:

```json
{ "type": "fader", "band": 3, "value": 0.7 }
{ "type": "preset_load", "name": "murf_default" }
{ "type": "param", "name": "drive", "value": 0.5 }
```

Server.js транслирует эти сообщения в соответствующие OSC-вызовы к sclang.

## Нюансы и риски

- **Питание** — Pi 3B чувствительна к качеству БП при одновременной работе Wi-Fi AP + realtime-аудио; брать с запасом по току.
- **Изоляция ядра** — без `isolcpus` веб-сервер/Wi-Fi-стек могут вызывать xrun'ы в аудио.
- **Импеданс источника** — пассивный звукоснимателе (гитара) требует буфера перед делителем, иначе теряются верха; line-level источники (синты) можно без буфера.
- **Земляные петли** — при подключении к внешним усилителям/микшерам продумать единую точку заземления, иначе гул 50Гц.
- **DC-смещение** — обязательна блокировка конденсатором перед ADC.

## Roadmap

- [x] Архитектура определена
- [ ] Заказана и получена плата DA7212 Audio Board (A)
- [ ] Базовая установка Raspberry Pi OS Lite + realtime-тюнинг
- [ ] SynthDef `\murf` — 8-полосный BPF-банк с envelope-модуляцией
- [ ] Pattern-движок (Routine/Tdef) на sclang
- [ ] OSC-роутинг между sclang и scsynth
- [ ] Node.js веб-сервер (Express + WebSocket)
- [ ] Веб-интерфейс (HTML/CSS/Vanilla JS) — фейдеры, паттерны
- [ ] Входная аналоговая цепочка (буфер + делитель + DC-блок)
- [ ] Тестирование на реальном инструменте
- [ ] Механизм смены пресетов (расширение под будущие эффекты)
