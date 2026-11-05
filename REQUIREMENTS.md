# Orbitext — Требования к проекту

## Обзор
Standalone Telegram-клиент для Apple Watch (без iOS-компаньона).
Платформа: watchOS 26.0+ (часы arm64) | Swift 6 | TDLib 1.8.64 | Bundle: `com.orbitext.app.watchkitapp` (iOS-обёртка `com.orbitext.app`)
Все пишется только под watchOS

---

## 1. Аутентификация

- [x] QR-код: отображение QR через Canvas, сканирование с телефона (Telegram → Настройки → Устройства → Привязать)
- [x] Вход по номеру телефона с кастомным цифровым пэдом
- [x] Ввод кода подтверждения (5 цифр, авто-отправка при заполнении + защита от двойной отправки через `didAutoSubmit`)
- [x] Двухфакторная аутентификация (пароль + подсказка)
- [x] Переключение между методами (QR ↔ телефон)
- [x] Отображение ошибок авторизации с кнопкой "Повторить" (`appState.retry()` сбрасывает `isInitialized`)
- [x] Logout с очисткой всех данных + сброс isInitialized для корректного повторного входа
- [x] Logout завершает сессию на сервере (`logOut`) и отзывает push-токен (`registerDevice` с пустым токеном), ожидание ограничено; прерванный logout дочищается при следующем запуске

---

## 2. Список чатов

- [x] Загрузка чатов порциями по 10 штук (пагинация)
- [x] Подгрузка следующей порции при достижении конца списка
- [x] Debounce пагинации 1.5 секунды между запросами (предотвращение chain-loading)
- [x] Список НЕ прыгает наверх при подгрузке новых чатов
- [x] handleChatUpdate НЕ вставляет новые чаты — только обновляет существующие в списке
- [x] Новые чаты попадают в список ТОЛЬКО через loadChats/loadMoreChats
- [x] Новые/последние чаты сверху
- [x] Секция закреплённых чатов (Pinned) с иконкой
- [x] Фолдеры (папки) — горизонтальные табы (All + пользовательские)
- [x] Долгое нажатие (context menu): отметить как прочитанное, закрепить/открепить
- [x] Единый компонент ChatListRow для pinned и regular чатов
- [x] Pull-to-refresh (+ flush офлайн-очереди)
- [x] Скелетон-загрузка при первом открытии (shimmer-анимация)
- [x] Пустое состояние "No Chats"
- [x] Баннер потери соединения
- [x] ~~Индикатор офлайн-очереди~~ (удалён — дублируется в ChatView и Settings)
- [x] Бейдж непрочитанных (синий, серый для замьюченных)

---

## 3. Строка чата (ChatRow)

- [x] Аватар с инициалами или иконкой группы (AvatarView)
- [x] Индикатор онлайн-статуса (зелёная точка)
- [x] Иконка закреплённого чата
- [x] Название чата + иконки (группа, мьют)
- [x] Превью: набор текста → черновик (красный) → последнее сообщение
- [x] Иконка типа контента (фото, видео, микрофон и т.д.)
- [x] Время последнего сообщения (через TimeFormatting.chatTimestamp)
- [x] Бейдж непрочитанных сообщений

---

## 4. Чат (просмотр сообщений)

- [x] Хронологический список сообщений (старые сверху, новые снизу; TDLib → `.reversed()`)
- [x] Разделители дат между днями (через TimeFormatting.dateSeparator)
- [x] Бабблы сообщений с асимметричными углами (BubbleShape)
  - Входящие: серые, слева
  - Исходящие: синие, справа
- [x] Имя отправителя в групповых чатах
- [x] Превью цитируемого сообщения (синяя полоска слева)
- [x] Индикатор прочтения (checkmark)
- [x] Временная метка
- [x] Реакции под сообщением (ReactionsBar: эмодзи + счётчик)
- [x] Индикатор набора текста (анимированные точки + имена)
- [x] Кнопка "Scroll to bottom" с счётчиком новых сообщений
- [x] onScrollVisibilityChange с fallback для watchOS < 11.0 (ScrollVisibilitySentinel ViewModifier)
- [x] Автопрокрутка к новому сообщению (если пользователь внизу)
- [x] Live-обновление через `appState.lastReceivedMessage` + `onChange`
- [x] Подавление уведомлений при активном чате (`NotificationManager.activeChatId`)
- [x] Очистка уведомлений при открытии чата
- [x] Отображение сообщений из офлайн-очереди ("Sending...")
- [x] Секция черновика
- [x] Retry загрузки сообщений при пустом ответе (500ms задержка, один повтор)

---

## 5. Типы контента сообщений

- [x] Текст (`.text`)
- [x] Фото (`.photo` - превью с соотношением сторон через PhotoThumbnailView из наименьшего размера шириной от 240 px (`previewFileId`), открытие в MediaViewer на полном размере)
- [x] Видео (`.video` — превью + длительность)
- [x] Голосовое (`.voice` - VoicePlayerView с прогрессом + длительность; файл качается по нажатию)
- [x] Стикер (`.sticker` — эмодзи крупно)
- [x] Анимация/GIF (`.animation`)
- [x] Документ (`.document` — имя + размер)
- [x] Unsupported (`.unsupported` — заглушка "[тип]")

---

## 6. Действия с сообщениями

- [x] Ответить (reply) — свайп влево или через confirmationDialog → программная навигация в ComposeView
- [x] Удалить сообщение (только исходящие, через confirmationDialog)
- [x] Переслать сообщение — ForwardChatPicker sheet через confirmationDialog
- [x] Редактировать текст — EditMessageSheet через confirmationDialog (только outgoing text)
- [x] Убрать реакцию — тап по существующей реакции переключает (add/remove)

---

## 7. Отправка сообщений (Compose)

- [x] Текстовое поле с автозагрузкой черновика
- [x] Автосохранение черновика через 1 секунду после остановки ввода
- [x] Быстрые эмодзи + быстрые ответы (один горизонтальный скролл, без разделения секциями) - TODO убрать их
- [x] Компактная компоновка: 2 секции (ввод + быстрые действия)
- [x] Контекст цитирования (имя + превью)
- [x] Автозакрытие после отправки
- [x] Кнопка "Отправить" неактивна при пустом тексте
- [x] Защита от двойной отправки (`isSending` guard)
- [x] Очистка задач при onDisappear (`draftSaveTask?.cancel()`)

---

## 8. Голосовые сообщения

- [x] Запись: AAC 16kHz моно (AVAudioSession)
- [x] Таймер записи (MM:SS, обновление каждые 0.1с)
- [x] Кнопка отмены записи (удаляет temp-файл)
- [x] Кнопка остановки и отправки
- [x] Воспроизведение: play/stop
- [x] Прогресс-бар воспроизведения + elapsed/total в MM:SS
- [x] Голосовые и аудио качаются по нажатию (downloadFile, приоритет `requested`) и играют по приходу; файл, который TDLib уже держит, играет сразу
- [x] Haptic feedback при начале/окончании записи

---

## 9. Медиа

- [x] Просмотр фото на полный экран (чёрный фон)
- [x] Зум Digital Crown (1x–4x)
- [x] Состояние загрузки (ProgressView) и ошибки ("Failed to load")
- [x] LRU-кэш медиа (25 MB лимит, SHA256 ключи)
- [x] Автоматическое вытеснение старых файлов

---

## 10. Поиск

- [x] Глобальный поиск по всем чатам
- [x] Поиск внутри конкретного чата — SearchView(chatId:) через NavigationLink в ChatView actions
- [x] Дебаунс 400мс
- [x] Результаты: имя отправителя, время, превью
- [x] Переход к чату из результата
- [x] Пустое состояние + состояние загрузки

---

## 11. Контакты

- [x] Список всех контактов с аватарами (AvatarView)
- [x] Поиск контактов (дебаунс 300мс, кэш `allContacts` для мгновенного восстановления)
- [x] Онлайн-статус / "последний раз был"
- [x] Карточка контакта: аватар, имя, телефон, username
- [x] Кнопка "Отправить сообщение" → ComposeView

---

## 12. Уведомления (Push)

- [x] Push-уведомления только для НОВЫХ сообщений (не при начальной синхронизации)
- [x] Замьюченные чаты НЕ отправляют push
- [x] Только нотифицируемые типы контента (фильтрация служебных)
- [x] Подавление push, когда пользователь просматривает этот чат (`activeChatId`, только пока приложение на экране)
- [x] Уведомления для любых чатов, не только первой страницы списка; решение по актуальному состоянию TDLib
- [x] Mute по умолчанию для типа чата (личные, группы, каналы) учитывается
- [x] Прочитанное на другом устройстве не уведомляет (`last_read_inbox_message_id`)
- [x] Фильтр папки по позициям чата в TDLib; при неизвестном членстве уведомление показывается
- [x] Звук не чаще раза в 3 секунды, сообщения не теряются
- [x] Ответ и Mark as Read из уведомления работают при холодном запуске
- [x] Спойлеры скрыты в уведомлениях, виджете, списке чатов, поиске и VoiceOver
- [x] Очистка доставленных уведомлений при открытии чата (`clearNotifications(for:)`)
- [x] Группировка по threadIdentifier (`chat_\(chatId)`)
- [x] Quick action: Reply (текстовый ввод)
- [x] Quick action: Mark as Read
- [x] clearBadge обёрнут в `#if os(iOS)` (недоступен на watchOS)

---

## 13. Офлайн-режим

- [x] Определение сетевого подключения через NWPathMonitor (Wi-Fi, Cellular, Bluetooth)
- [x] Баннер "Waiting for network..." (ConnectionStatusView)
- [x] Своя очередь только для сообщений, которые TDLib не принял (клиент не запущен/закрыт, FLOOD_WAIT); остальное TDLib держит в своей очереди
- [x] Отклонённое сообщение сразу помечается как неотправленное (Retry/Remove), черновик сохраняется
- [x] Повтор отправки при восстановлении (макс. 5 попыток, экспоненциальная задержка 2^retryCount)
- [x] Персистентная очередь (`pending_messages.json`)
- [x] Отображение ожидающих сообщений в чате ("Sending...")
- [x] Flush очереди при pull-to-refresh

---

## 14. Черновики

- [x] Автосохранение текста при выходе из Compose
- [x] Восстановление черновика при входе в Compose
- [x] Синхронизация черновиков с Telegram (setDraft/getDraft через TDLib)
- [x] Отображение "Draft:" (красным) в списке чатов и в чате
- [x] Очистка черновика после отправки
- [x] Персистентное хранение (`drafts.json`, thread-safe NSLock)

---

## 15. Haptic Feedback

- [x] Отправка сообщения → `.success`
- [x] Получение сообщения → `.notification`
- [x] Ошибка → `.failure`
- [x] Нажатие → `.click`
- [x] Добавление реакции → `.directionUp`
- [x] Начало записи → `.start`
- [x] Окончание записи → `.stop`

---

## 16. Настройки

- [x] Статус подключения + тип соединения (Wi-Fi/LTE/BT, зелёный/красный бейдж)
- [x] Количество сообщений в очереди ("N queued")
- [x] Переключатель уведомлений (с проверкой авторизации после `requestPermission`)
- [x] Размер кэша + кнопка очистки (каталог TDLib + VoiceManager; медиа хранит TDLib)
- [x] Выход из аккаунта (с подтверждением через confirmationDialog)
- [x] Информация о версии (0.1.0)

---

## 17. Виджеты

- [x] Circular: иконка + счётчик непрочитанных
- [x] Corner: иконка + "N unread"
- [x] Rectangular: название приложения + последний чат + превью
- [x] Inline: "N unread messages"
- [x] Синхронизация через shared UserDefaults (`group.com.orbitext.shared`)
- [x] Guard от недоступного App Group (syncWidget не падает без entitlement)
- [x] Обновление каждые 15 минут
- ⚠️ Зависимость `OrbitextWidgetExtension` закомментирована в project.yml (ошибка "Invalid placeholder attributes" на симуляторе)

---

## 18. TDLib интеграция

- [x] Подключение через tdjson C API (статические библиотеки, bridging header `TDJsonClient.h`)
- [x] Обёртка TDJsonWrapper: async/await, request-response matching через `@extra`
- [x] Корректный deinit: `stop()` отменяет receiveTask + резюмирует все pending continuations с `TDError.clientClosed`
- [x] Кэширование чатов и пользователей (thread-safe NSLock: `cacheLock` + getter/setter методы)
- [x] Обработка всех типов updateAuthorizationState
- [x] Автоперезапуск при закрытии (макс. 3 попытки, экспоненциальная задержка)
- [x] Очистка БД при ошибке auth_key
- [x] API credentials: Info.plist (`TDLIB_API_ID`, `TDLIB_API_HASH`) через xcconfig; реальные значения хранятся только в локальном `Orbitext.local.xcconfig`
- [x] Оптимизация для снижения FLOOD_WAIT:
  - `use_chat_info_database: false`
  - `disable_top_chats: true`
  - `ignore_background_updates: true`
  - `ignore_inline_thumbnails: true`
  - Задержка загрузки фолдеров на 5 секунд
  - Лимит чатов в фолдерах: 20
  - Debounce handleNewMessage для неизвестных чатов (3 сек, один loadChats)
  - handleChatUpdate не вставляет новые чаты из TDLib апдейтов
  - Debounce пагинации 1.5 сек между loadMoreChats
- [x] Фильтрация шумных обновлений из логов

---

## 19. Архитектура

- **@Observable** (Observation framework) — не ObservableObject
- **TelegramServiceProtocol** — абстракция над TDLibService
- **AppState** — центральный @Observable контейнер состояния
  - `retry()` — сброс `isInitialized` + повторная инициализация
  - Пагинация: по 10 чатов, debounce 1.5s, без chain-loading
  - `lastReceivedMessage` — для live-обновления ChatView
  - `syncWidget()` — запись в shared UserDefaults + WidgetCenter.reloadAllTimelines
- **TDLibService** - корень композиции транспорта и последовательности старта, logout, сброса и восстановления; запросы в расширениях `+Auth`, `+Chats`, `+Messages`, `+Files` и других. Состояние у частей, каждая в одном `Mutex`:
  - `TDClientSession` - текущий клиент, поколение, переход, id аккаунта, поток событий
  - `TDRequestSender` - throttled и локальные запросы, `FLOOD_WAIT`
  - `AuthCoordinator` - состояния авторизации на одной очереди, параметры TDLib, QR
  - `PushRegistrar` - регистрация APNs-токена, remote push
  - `PresenceController` - статус online, пауза receive loop
- **TDJsonWrapper** — низкоуровневая обёртка C API:
  - `send()` — async request с CheckedContinuation
  - `sendAsync()` — fire-and-forget
  - `execute()` — синхронный запрос
  - `startReceiveLoop()` — фоновый Task.detached для td_receive
- **Async/await** повсеместно (без Combine)
- **Canvas-based QR** — рендеринг без внешних зависимостей (Vendor/QRCodeGenerator)
- **File-based persistence** — черновики, очередь, кэш через FileManager
- **Keychain** — API ID / Hash через Info.plist / xcconfig
- **TimeFormatting** — централизованные утилиты форматирования дат (chatTimestamp, dateSeparator, duration)
- **Навигация** — ChatListView как корневой экран (без TabView). Settings — gear icon в toolbar, Search — magnifyingglass в toolbar, Contacts — секция внизу списка чатов

---

## 20. Файловая структура

```
Orbitext/
├── App/              OrbitextApp.swift, AppState.swift
├── Models/           AuthState, ChatModel, MessageModel, ContactModel, FolderModel
├── Telegram/         TelegramServiceProtocol, TDLibService (+Auth, +Chats, +Messages,
│                     +Files, ...), TDClientSession, TDRequestSender, AuthCoordinator,
│                     PushRegistrar, PresenceController, TDJsonWrapper, TDJsonClient.h,
│                     TDLibEvent
├── Services/         HapticManager, NotificationManager, MessageQueue,
│                     NetworkMonitor, DraftStore, VoiceManager
├── Cache/            ImageCache (LRU в памяти над файлами TDLib), SharedPlaybackFiles
├── Vendor/           QRCodeGenerator (8 файлов)
└── Views/
    ├── Auth/         AuthFlowView, QRLoginView, PhoneInputView, CodeInputView, TwoFactorView
    ├── ChatList/     ChatListView (ChatListRow, ChatRowSkeletonView, FolderTab), ChatRowView
    ├── Chat/         ChatView (DateSeparatorView, ScrollVisibilitySentinel),
    │                 MessageRow (BubbleShape), ReactionsBar, ReactionPickerView,
    │                 VoiceRecorderView, VoicePlayerView,
    │                 MediaViewer, PhotoThumbnailView, ProfileView
    ├── Contacts/     ContactsView (ContactRow, ContactDetailView)
    ├── Search/       SearchView
    ├── Compose/      ComposeView
    ├── Settings/     SettingsView
    └── Components/   AvatarView, ConnectionStatusView, TimeFormatting, TypingIndicatorView
Orbitext.xcconfig    TDLib linking flags (headers, libs, ldflags)
OrbitextWidget/          OrbitextWidget.swift
```

---

## 21. Технические ограничения

- watchOS: стандартная клавиатура неудобна → кастомный цифровой пэд для авторизации
- TDLib: не скомпилирован для watchOS simulator → TDLibService используется напрямую
- FLOOD_WAIT: Telegram rate-limiting при массовом prefetch → debounce + оптимизация параметров TDLib
- arm64e (Apple Watch Ultra): TDLib arm64 бинарники совместимы через ABI
- Размер кэша: ограничен 25MB для экономии места на часах
- setBadgeCount: недоступен на watchOS → обёрнут в `#if os(iOS)`
- onScrollVisibilityChange: только watchOS 11+ → fallback на onAppear (ScrollVisibilitySentinel)
- App Group UserDefaults: может быть недоступен без entitlement → guard в syncWidget
- NSAppTransportSecurity: `NSAllowsArbitraryLoads` включен намеренно (project.yml, закреплено в `PackagedConfigurationTests`): когда QUIC и WebSocket заблокированы, TDLib переходит на обычный HTTP к IP-адресам Telegram. Приемлемость исключения для App Store review остается открытым вопросом
- Widget: зависимость закомментирована — ошибка "Invalid placeholder attributes" на watchOS Simulator

---

## 22. Нереализованные фичи (TODO)

- [x] UI для пересылки сообщений — ForwardChatPicker sheet
- [x] UI для редактирования сообщений — EditMessageSheet (outgoing text)
- [x] UI для поиска внутри конкретного чата — SearchView(chatId:)
- [x] Убрать реакцию через UI — тап по реакции переключает add/remove
- [ ] Скомпилировать TDLib для watchOS (device + simulator)
- [ ] Раскомментировать widget dependency после исправления ошибки симулятора

---

## 23. Безопасность и хранение данных

- [ ] Хранение сессии/токенов в Keychain (не UserDefaults)
- [x] Шифрование локальной БД TDLib (database_encryption_key в setTdlibParameters)
- [x] Полная очистка данных при логауте (кэш, черновики, очередь, voice recordings)
- [ ] Политика автоочистки медиа-файлов (по возрасту или при превышении лимита)
- [ ] Запрет скриншотов для экранов с чувствительным контентом (если поддерживается watchOS)

---

## 24. Управление памятью и ресурсами

- [ ] Соблюдение лимитов RAM watchOS (~30–50 MB)
- [ ] Стратегия работы в фоне (WKExtendedRuntimeSession для голосовых сообщений)
- [x] Корректное поведение при `scenePhase` active/background (reload чатов, stop voice)
- [x] TDLib receive loop pause/resume при переходе в фон (CheckedContinuation gate, 0% CPU в фоне)
- [x] NWPathMonitor pause/resume (cancel + new instance при active, Apple-рекомендуемый паттерн)
- [x] TelegramServiceProtocol: `suspendForBackground()` / `resumeFromBackground()` — единый интерфейс
- [x] AppState lifecycle orchestration: background → stop voice + pause network + suspend TDLib; active → resume TDLib + resume network + reload chats + flush queue
- [x] AVAudioSession deactivation после записи/воспроизведения (`.notifyOthersOnDeactivation`)
- [x] Отмена searchTask при уходе со SearchView/ContactsView (`.onDisappear`)
- [x] DraftStore: coalesced writes (0.5s debounce через DispatchWorkItem)
- [ ] Отмена или отложенность тяжёлых операций при низком заряде батареи
- [x] Ленивая загрузка аватаров и превью: в чате медиа строки вне окна не качается (`isMediaWanted` из `onScrollVisibilityChange`), списки строят только видимые строки; строка, о которой колбэк ничего не сообщил, грузится через две секунды. Страница галереи альбома качает превью и фото только на экране. На часах не проверялось
- [ ] Освобождение ресурсов при memory warning

---

## 25. Accessibility (Доступность)

- [ ] VoiceOver поддержка для всех экранов и интерактивных элементов
- [ ] Dynamic Type (масштабирование шрифтов)
- [ ] Достаточная контрастность UI-элементов (WCAG AA)
- [ ] Accessibility labels для иконок и кнопок без текста
- [ ] Корректный порядок навигации VoiceOver в списках и чатах

---

## 26. Локализация

- [ ] Поддерживаемые языки: English (EN), Русский (RU)
- [ ] Все строки вынесены в `Localizable.strings` / String Catalogs
- [ ] Форматирование дат/чисел по локали пользователя
- [ ] Плюрализация (1 сообщение / 2 сообщения / 5 сообщений)
- [ ] Язык приложения следует системным настройкам watchOS

---

## 27. Профиль пользователя

- [ ] Просмотр своего профиля (аватар, имя, username, телефон)
- [x] Просмотр профиля собеседника (через ProfileView — доступен для всех типов чатов)
- [x] Информация о группе/канале: название, описание, количество участников (getSupergroupFullInfo/getBasicGroupFullInfo)
- [ ] Список участников группы (с пагинацией)
- [ ] Редактирование своего профиля (имя, фамилия) — опционально

---

## 28. Группы и каналы

- [x] Визуальное различие: личные чаты (avatar), группы (person.2), каналы (megaphone)
- [x] Каналы: режим только чтения (скрытие ComposeView и VoiceRecorder)
- [ ] Группы: отображение имени отправителя
- [ ] Уведомления о системных событиях (join/leave/pin) — отображение, но без push
- [ ] Супергруппы: поддержка больших списков участников

---

## 29. Обработка ошибок

- [x] Категоризация ошибок TDLib (TDError: isFloodWait, isSessionRevoked, floodWaitSeconds)
- [x] `SESSION_REVOKED` / `AUTH_KEY_UNREGISTERED` → автоматический logout
- [x] `FLOOD_WAIT` → отображение таймера ожидания + auto-dismiss
- [x] Единый механизм показа ошибок (handleError → toast с auto-dismiss для FLOOD_WAIT)
- [ ] Retry-политика: экспоненциальная задержка для сетевых запросов
- [ ] Graceful degradation при недоступности отдельных функций

---

## 30. Обновление данных и синхронизация

- [x] Re-sync при возвращении из фона (scenePhase .active → loadChats + flushMessageQueue)
- [ ] Обработка конфликтов: удалённое сообщение, архивированный чат, заблокированный пользователь
- [ ] Опциональная секция архивированных чатов
- [ ] Инкрементальная синхронизация (не перезагружать всё)
- [x] Обработка `updateDeleteMessages` (удаление из ChatView + обновление lastMessage)
- [ ] Обработка `updateChatIsMarkedAsUnread`, `updateChatArchived`

---

## 31. Производительность

- [ ] Целевое время холодного старта: < 3 секунд
- [ ] Плавный скролл списка чатов и сообщений (60 FPS)
- [ ] Максимальный размер приложения: < 50 MB (с TDLib)
- [ ] Логирование крашей (os_log / crash reports)
- [ ] Профилирование памяти и CPU в Instruments

---

## 32. Анимации и переходы

- [ ] Навигационные переходы: NavigationStack push (чаты → чат → compose)
- [ ] Sheet-переходы: MediaViewer, VoiceRecorder
- [ ] Shimmer-анимация скелетонов при загрузке
- [ ] Плавное появление новых сообщений (withAnimation)
- [ ] Анимация typing indicator (пульсирующие точки)
- [ ] Анимация прогресса загрузки медиа

---

## 33. Управление жестами

- [ ] Digital Crown: скролл списков, зум фото (1x–4x)
- [x] Long press на сообщении → confirmationDialog (reply, react, delete)
- [x] Long press в списке чатов → context menu (pin/unpin, mark read)
- [x] Свайп влево на сообщении → reply (навигация в ComposeView)
- [ ] Tap на фото → открытие MediaViewer

---

## 34. Неподдерживаемые функции (out of scope)

- Видео/аудио звонки
- Боты (inline-режим, клавиатуры ботов, платежи)
- Секретные чаты (E2E шифрование)
- Стикер-паки (загрузка/просмотр наборов)
- Отправка файлов/медиа с часов
- Scheduled messages (отложенные сообщения)
- Polls / викторины
- Темы (topics) в супергруппах
- Истории (Stories)
- Премиум-функции Telegram
