import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.policyText())
                    .font(.caption2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background { WristGlassBackground() }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .navigationTitle(L10n.string("Privacy Policy"))
        .background { WristScreenBackground() }
    }

    private static func policyText() -> String {
        let lang = (Bundle.main.preferredLocalizations.first ?? Locale.current.identifier).lowercased()
        let prefix = lang.prefix(2)
        return (prefix == "ru" || prefix == "uk" || prefix == "be") ? russianText : englishText
    }

    private static let englishText = """
    Orbitext Privacy Policy
    Effective date: 2026-05-18

    Orbitext (the App) is an independent, third-party client for the Telegram messaging platform, designed for Apple Watch. It is not affiliated with, endorsed by, or sponsored by Telegram FZ-LLC. This policy explains what data the App processes, where it goes, and what choices you have.

    1. Who we are
    Orbitext is developed and maintained by an individual developer. Contact: @vldlb on Telegram.

    2. Data the App processes
    Telegram account data. To use the App you sign in with your Telegram account using your phone number. All communication with Telegram servers is performed by the official TDLib library bundled with the App. Your messages, chats, contacts, and media are handled by Telegram according to the Telegram Privacy Policy. We do not operate Telegram servers and we never receive a copy of your messages.

    Local cache on your device. The App stores Telegram session data, downloaded media, and message previews in the App sandbox on your Apple Watch. You can clear this cache in Settings -> Storage -> Clear Cache, or by deleting the App. The data never leaves your device.

    Push notification token (APNs). If you enable notifications, Apple's push service provides a device token that is sent to Telegram so they can deliver message notifications. No content of the message leaves Telegram via this channel beyond what Telegram's own push system carries.

    Diagnostic logs. The App writes local logs on your device for troubleshooting. Logs stay on the device unless you explicitly share them with the developer when reporting an issue.

    3. Data we do not collect
    The App does not have its own analytics backend. It does not contain advertising SDKs, attribution SDKs, or third-party trackers. Your phone number is sent only to Telegram during sign-in, never to us. Data obtained from Telegram is never used to train or develop AI or machine-learning models.

    4. Third-party services
    - Telegram. All messaging functionality. See the Telegram Privacy Policy at telegram.org/privacy.
    - Apple Push Notification service. Notification delivery. See Apple's Privacy Policy.

    5. Your rights
    You can sign out at any time (Settings -> Account -> Log Out), which clears your Telegram session from the device. To delete your Telegram account entirely, use the Telegram service directly. To delete all locally cached App data, delete the App.

    6. Children
    The App is not directed at children under 13. The same age rules as Telegram itself apply.

    7. Changes
    If this policy changes, the new version will appear in the App and at vsiioky.github.io/orbitext/privacy.html, and the effective date above will be updated.

    8. Contact
    Questions, problems, data requests: @vldlb on Telegram.
    """

    private static let russianText = """
    Политика конфиденциальности Orbitext
    Дата вступления в силу: 2026-05-18

    Orbitext (Приложение) - независимый сторонний клиент мессенджера Telegram для Apple Watch. Orbitext не связан с Telegram FZ-LLC, не одобрен и не спонсируется ею. Этот документ описывает, какие данные обрабатывает Приложение, куда они уходят и какие у вас есть права.

    1. Кто мы
    Orbitext разрабатывается и поддерживается независимым разработчиком. Связь: @vldlb в Telegram.

    2. Какие данные обрабатывает Приложение
    Данные аккаунта Telegram. Для работы Приложения вы входите в свой аккаунт Telegram по номеру телефона. Всё взаимодействие с серверами Telegram выполняется официальной библиотекой TDLib, встроенной в Приложение. Сообщения, чаты, контакты и медиа обрабатываются Telegram согласно Политике конфиденциальности Telegram. Мы не управляем серверами Telegram и никогда не получаем копию ваших сообщений.

    Локальный кеш на устройстве. Приложение хранит данные сессии Telegram, скачанные медиа и превью сообщений в песочнице Приложения на ваших Apple Watch. Кеш можно очистить в "Настройки -> Хранилище -> Очистить кеш" или удалив Приложение. Эти данные не покидают ваше устройство.

    Токен push-уведомлений (APNs). Если уведомления включены, служба Apple Push выдаёт токен устройства, который передаётся в Telegram для доставки уведомлений о сообщениях. Содержимое сообщений по этому каналу не передаётся за пределы того, что и так передаёт push-система Telegram.

    Диагностические логи. Приложение пишет локальные логи на устройстве для отладки. Логи остаются на устройстве, пока вы явно не отправите их разработчику при репорте проблемы.

    3. Что Приложение НЕ собирает
    У Приложения нет собственного аналитического бэкенда. В нём нет рекламных SDK, атрибуционных SDK или сторонних трекеров. Ваш номер телефона уходит только в Telegram при входе - не к нам. Данные, полученные от Telegram, никогда не используются для обучения или разработки моделей ИИ и машинного обучения.

    4. Сторонние сервисы
    - Telegram. Вся функциональность мессенджера. Смотрите Политику конфиденциальности Telegram на telegram.org/privacy.
    - Apple Push Notification service. Доставка уведомлений. Смотрите Политику конфиденциальности Apple.

    5. Ваши права
    Вы можете выйти из аккаунта в любое время ("Настройки -> Аккаунт -> Выйти"), что очищает сессию Telegram с устройства. Чтобы удалить аккаунт Telegram целиком - используйте сервис Telegram напрямую. Чтобы удалить все локальные данные Приложения - удалите Приложение.

    6. Дети
    Приложение не предназначено для детей младше 13 лет. Действуют те же возрастные правила, что и у самого Telegram.

    7. Изменения
    Если политика меняется, новая версия публикуется в Приложении и на vsiioky.github.io/orbitext/privacy.html, а дата вступления в силу выше обновляется.

    8. Связь
    Вопросы, проблемы, запросы по данным: @vldlb в Telegram.
    """
}
