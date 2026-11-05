import SwiftUI
import WatchKit

enum AppConstants {
    enum Chat {
        static let loadLimit = 10
        static let paginationThrottle: TimeInterval = 1.5
        /// How long a notification waits for this client's first page of the
        /// selected folder before it is shown with unknown membership.
        static let notificationFolderWait: TimeInterval = 5
    }

    enum Message {
        static let charLimit = 4096
        static let charWarningThreshold = 3900
        static let charDangerThreshold = 4000
        static let loadRetryCount = 3
        static let retryBaseDelay = 500 // milliseconds
        static let minMessageCount = 5
        static let searchLimit = 20
        /// A page of history. Every loaded row stays rendered in the eager
        /// timeline, so a page is what one screenful of scrolling can use.
        static let defaultLoadLimit = 20
        /// Lines a message shows before "Show more". A rendered text is a
        /// bitmap of its whole height that the eager timeline keeps for every
        /// row; a long bot message alone took 2-3 MB.
        static let collapsedLineLimit = 12
    }

    enum Queue {
        static let floodWaitDelay: TimeInterval = 0.5
        static let failureBackoff: TimeInterval = 2.0
        static let maxRetries = 5
    }

    enum Draft {
        static let changeDebounce: TimeInterval = 1.0
    }

    enum Network {
        static let requestTimeoutNanos: UInt64 = 30_000_000_000
        static let searchDebounce = 400 // milliseconds
    }

    enum Cache {
        static let maxSize = 25 * 1024 * 1024
        static let userCacheSize = 500
        /// What the image cache keeps of decoded pictures while the app is in
        /// the background (of up to 12 MB): the latest ones, which the screen
        /// the user comes back to draws.
        static let backgroundDecodedImageBytes = 2 * 1024 * 1024
    }

    enum App {
        static let version = "0.1.0"
        static let widgetSuite = "group.com.orbitext.shared"
        static let maxRestarts = 3
        static let backgroundRefreshInterval: TimeInterval = 1800
        static let remotePushSyncDelay: TimeInterval = 0.75
        /// How long a notification action waits for TDLib authorization after
        /// a cold launch before its reply is kept in the offline queue.
        static let notificationActionReadyTimeout: TimeInterval = 10
        /// How long a notification reply keeps the app awake for the server
        /// result. TDLib retries the pending message itself after a timeout.
        static let notificationActionDeliveryTimeout: TimeInterval = 10
        /// How long logout waits for the server (push unregister + logOut)
        /// before wiping the session locally anyway.
        static let logoutServerTimeout: TimeInterval = 8
        static let supportUsername = "vldlb"
        static let supportURL = URL(string: "https://t.me/vldlb")!

        private static let privacyPolicyURLEN = URL(string: "https://vsiioky.github.io/orbitext/privacy.html")!
        private static let privacyPolicyURLRU = URL(string: "https://vsiioky.github.io/orbitext/privacy.ru.html")!

        /// Localized privacy policy URL. Picks Russian for ru/uk/be locales, English otherwise.
        static var privacyPolicyURL: URL {
            let lang = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
            let prefix = lang.lowercased().prefix(2)
            return (prefix == "ru" || prefix == "uk" || prefix == "be") ? privacyPolicyURLRU : privacyPolicyURLEN
        }
    }

    enum Mute {
        static let indefiniteDuration = 2_147_483_647
    }

    enum Auth {
        static let codeLength = 5
    }

    // MARK: - UI Constants

    enum UI {
        /// Common font sizes used across the watch UI.
        enum FontSize {
            static let micro: CGFloat = 7 // checkmarks, pin icons
            static let tiny: CGFloat = 8 // timestamps, duration labels, forwarding text
            static let small: CGFloat = 9 // date separators, status text, time labels, folder tabs
            static let body: CGFloat = 10 // reply previews, reactions, quick replies, scroll button
        }

        /// Auth numeric keypad sizing. Scales to the host watch so the 4-row
        /// grid plus phone/code entry field plus Next button fits without
        /// scrolling. Tier brackets follow WatchKit screen-height groupings:
        ///
        ///   <= 170pt : 38mm (Series 0-3)
        ///   <= 200pt : 40mm (Series 4-6, SE)
        ///   <= 224pt : 41mm (S7-S9), 42mm (S10), 44mm (SE)
        ///   <= 242pt : 45mm (S7-S10)
        ///    > 242pt : 49mm Ultra
        enum Keypad {
            private static var screenHeight: CGFloat {
                WKInterfaceDevice.current().screenBounds.height
            }

            static var keyHeight: CGFloat {
                switch screenHeight {
                case ...170: return 28
                case ...200: return 30
                case ...224: return 32
                case ...242: return 34
                default: return 38
                }
            }

            static var spacing: CGFloat {
                screenHeight <= 200 ? 2 : 3
            }

            static var digitFontSize: CGFloat {
                switch screenHeight {
                case ...170: return 14
                case ...200: return 15
                case ...224: return 16
                case ...242: return 18
                default: return 20
                }
            }

            static var deleteIconSize: CGFloat {
                switch screenHeight {
                case ...170: return 12
                case ...200: return 13
                case ...224: return 14
                case ...242: return 15
                default: return 16
                }
            }
        }

        /// Avatar sizes.
        enum Avatar {
            static let standard: CGFloat = 32 // chat list rows, default
            static let contact: CGFloat = 30 // contact rows
            static let profile: CGFloat = 50 // profile / contact detail headers
        }

        /// Message bubble layout values.
        enum Bubble {
            static let horizontalPadding: CGFloat = 8
            static let verticalPadding: CGFloat = 5
            static let cornerRadius: CGFloat = 10
            static let spacerMinLength: CGFloat = 16
        }

        /// Skeleton / shimmer placeholder values.
        enum Skeleton {
            static let spacerMinLength: CGFloat = 30
            static let avatarSize: CGFloat = 32
        }

        /// Sticker and video-note shared dimensions.
        enum Sticker {
            static let size: CGFloat = 72
        }

        /// Photo and video thumbnail constraints.
        enum Thumbnail {
            static let maxWidth: CGFloat = 120
            static let minHeight: CGFloat = 40
            static let maxHeight: CGFloat = 100
            static let cornerRadius: CGFloat = 6
            static let videoNoteSize: CGFloat = 72
            /// Width of a decoded thumbnail, in pixels: 2x the tile's width in
            /// points. A photo smaller than this would be stretched to fill it.
            static var pixelWidth: Int { Int(maxWidth * 2) }
        }

        /// The full-screen photo viewer and the album gallery around it.
        enum Viewer {
            /// Longest side, in pixels, of a photo the viewer decodes. The
            /// bitmap is 4 bytes a pixel, so an HD photo of 2560 px is 20-26 MB
            /// and one of 1280 px is 5-6.5 MB, on a screen 422 px wide: the
            /// Digital Crown zooms in about 3x before this bound shows.
            /// Photos within the bound keep the pixels they have.
            static let maxPixelSize = 1280
            /// How many pages away from the selected one a gallery page keeps
            /// its decoded photo: the neighbours a swipe reaches next.
            static let galleryKeptPageReach = 1
        }

        /// Bot inline keyboards, the bot menu and bot notices.
        enum BotKeyboard {
            static let spacing: CGFloat = 3
            static let buttonMinHeight: CGFloat = 30
            static let buttonCornerRadius: CGFloat = 9
            static let menuButtonWidth: CGFloat = 36
            static let linkQRSize: CGFloat = 120
            static let noticeDuration = 2.5
        }

        /// Standard list-row insets used for message rows, typing indicators, etc.
        static let messageRowInsets = EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        static let compactRowInsets = EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)

        /// Unread badge pill padding.
        enum Badge {
            static let horizontalPadding: CGFloat = 4
            static let verticalPadding: CGFloat = 1
            /// Size of mention/reaction circle-icon badges (at.circle.fill,
            /// heart.circle.fill) in the chat row trailing column.
            static let iconSize: CGFloat = 16
        }

        /// ScrollToBottom button dimensions.
        enum ScrollButton {
            static let horizontalPadding: CGFloat = 10
            static let verticalPadding: CGFloat = 5
            static let bottomPadding: CGFloat = 6
        }
    }
}
