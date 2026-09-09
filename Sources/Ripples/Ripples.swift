import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Public entry point to the Ripples Metrics (ripples.sh) SDK.
///
/// Usage:
///
///     // iOS is a client SDK — use the project token (UUID), never the `priv_` secret key.
///     Ripples.setup(RipplesConfig(projectToken: "<your project token>"))
///     Ripples.shared.identify("user_123", traits: ["email": "jane@example.com"])
///     Ripples.shared.track("created a budget", userId: "user_123",
///                          properties: ["area": "budgets"])
///
/// The instance is process-wide. Events are persisted to disk and delivered
/// in batches; calls return immediately and never throw.
public final class Ripples {

    public static let shared = Ripples()

    private var config: RipplesConfig?
    private var api: RipplesApi?
    private var queue: RipplesQueue?
    private var storage: RipplesStorage?
    private var context: RipplesContext?
    private var reachability: RipplesReachability?
    private var visitorId: String?

    /// Persisted user id from the most recent `identify()` call. Injected as
    /// `$user_id` on every subsequent event so the backend doesn't have to
    /// backfill identity after the fact.
    private let userIdLock = NSLock()
    private var userId: String?

    private let setupLock = NSLock()
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Traits cached from the last `identify()` call. Auto-included in every
    /// subsequent event so the backend can keep user records fresh without
    /// requiring an explicit `identify()` on every session.
    private let traitsLock = NSLock()
    private var cachedTraits: [String: Any] = [:]

    private init() {}

    /// Initialize the SDK. Safe to call multiple times — subsequent calls
    /// after the first are ignored.
    @discardableResult
    public static func setup(_ config: RipplesConfig) -> Ripples {
        shared.configure(config)
        return shared
    }

    private func configure(_ config: RipplesConfig) {
        setupLock.withLock {
            guard self.config == nil else {
                ripplesDebug("Ripples already initialized; ignoring setup()")
                return
            }
            self.config = config
            let storage = RipplesStorage(projectToken: config.projectToken)
            let api = RipplesApi(config)
            let reachability = RipplesReachability()
            let queue = RipplesQueue(config: config, api: api, storage: storage, reachability: reachability)
            let context = RipplesContext()

            // Restore or generate a persistent anonymous visitor ID.
            let storedId = storage.readString(.visitorId)
            let vid = storedId ?? UUID().uuidString.lowercased()
            if storedId == nil { storage.writeString(.visitorId, vid) }

            self.storage = storage
            self.api = api
            self.queue = queue
            self.context = context
            self.reachability = reachability
            self.visitorId = vid
            self.userId = storage.readString(.userId)

            queue.start()
            registerLifecycleObservers()
        }
    }

    // MARK: - Public API

    /// Set or update traits on a user. Extra keys become custom properties.
    ///
    /// Traits are also cached locally so they can be included in subsequent
    /// `track` and `screen` events — keeping the user record fresh without
    /// requiring a separate `identify` call on every session.
    public func identify(_ userId: String, traits: [String: Any] = [:]) {
        if !traits.isEmpty {
            traitsLock.withLock {
                for (k, v) in traits { cachedTraits[k] = v }
            }
        }
        userIdLock.withLock { self.userId = userId }
        storage?.writeString(.userId, userId)
        enqueue("identify", merging: ["$user_id": userId], with: traits)
    }

    /// Track a significant product-usage event.
    ///
    /// Use ONLY for actions that prove a user got real value from your product
    /// (created a budget, sent a message, invited a teammate). This is NOT a
    /// generic event log like PostHog or Mixpanel — do not send pageviews,
    /// banner impressions, button taps, or "viewed X" events. Every `track`
    /// call feeds the Activation dashboard, so noise pollutes your funnel.
    ///
    /// - Parameters:
    ///   - actionName: The action name (e.g. `"created a budget"`).
    ///   - area: Optional product area (e.g. `"budgets"`). Groups actions for
    ///     adoption analysis in the Ripples dashboard. Ignored if `properties`
    ///     already contains an `"area"` key.
    ///   - properties: Additional properties — may include `activated: true`
    ///     to mark this occurrence as the activation moment, plus any custom keys.
    ///   - userProperties: Traits to attach alongside this event so the backend
    ///     can upsert the user record without a separate `identify` call. When
    ///     `nil`, the traits cached from the last `identify()` are used instead.
    ///     Pass an empty dictionary to suppress trait forwarding entirely.
    public func track(_ actionName: String,
                      area: String? = nil,
                      properties: [String: Any] = [:],
                      userProperties: [String: Any]? = nil)
    {
        var props = properties
        var base: [String: Any] = ["$name": actionName]
        if let area = area {
            base["$area"] = area
        }
        // Move system keys from user properties to $-prefixed system keys.
        if let area = props.removeValue(forKey: "area") {
            if base["$area"] == nil { base["$area"] = area }
        }
        if let activated = props.removeValue(forKey: "activated") {
            base["$activated"] = activated
        }
        let traits = userProperties ?? traitsLock.withLock { cachedTraits.isEmpty ? nil : cachedTraits }
        if let traits = traits, !traits.isEmpty {
            base["$traits"] = traits
        }
        enqueue("track", merging: base, with: props)
    }

    /// Record a screen view. Call this when a screen becomes visible, or use
    /// the `.trackScreen(_:)` SwiftUI modifier instead.
    ///
    /// The screen name is stored in `path` (e.g. `"/Home"`) and appears in
    /// the Pages report alongside web pageviews.
    ///
    /// - Parameters:
    ///   - screenName: The screen name (e.g. `"Home"`).
    ///   - area: Optional product area to group this screen with related actions.
    ///     Ignored if `properties` already contains an `"area"` key.
    ///   - properties: Additional properties merged into the pageview event.
    ///   - userProperties: Traits to attach alongside this event so the backend
    ///     can upsert the user record. Falls back to cached traits from `identify()`.
    ///     Pass an empty dictionary to suppress trait forwarding entirely.
    public func screen(_ screenName: String,
                       area: String? = nil,
                       properties: [String: Any] = [:],
                       userProperties: [String: Any]? = nil)
    {
        var props = properties
        var base: [String: Any] = [
            "$name": screenName,
            "$path": screenName,
        ]
        if let area = area {
            base["$area"] = area
        } else if let area = props.removeValue(forKey: "area") {
            base["$area"] = area
        }

        // Mark the first screen in a new session as the session entry.
        if let ctx = context, ctx.isFirstScreenInSession {
            base["$session_start"] = true
            ctx.markSessionStartSent()
        }

        let traits = userProperties ?? traitsLock.withLock { cachedTraits.isEmpty ? nil : cachedTraits }
        if let traits = traits, !traits.isEmpty {
            base["$traits"] = traits
        }

        enqueue("pageview", merging: base, with: props)
    }

    /// Force-flush the queue. The completion fires once the in-flight batch
    /// finishes (or immediately if the queue was empty / paused).
    public func flush(completion: (() -> Void)? = nil) {
        guard let queue = self.queue else { completion?(); return }
        if let completion = completion {
            queue.flushSync(completion: completion)
        } else {
            queue.flush()
        }
    }

    /// Internal — visible for tests.
    var queueDepth: Int { queue?.depth ?? 0 }

    /// Internal — visible for tests. Decoded properties of the most recently
    /// enqueued event, or nil if the queue is empty.
    var lastEnqueuedProperties: [String: Any]? {
        guard let queue = self.queue else { return nil }
        let all = queue.peekAll()
        guard let data = all.last else { return nil }
        return RipplesEvent.fromData(data)
    }

    /// Internal — visible for tests.
    func reset() {
        setupLock.withLock {
            queue?.stop()
            queue?.clear()
            for token in lifecycleObservers {
                NotificationCenter.default.removeObserver(token)
            }
            lifecycleObservers.removeAll()
            queue = nil
            api = nil
            storage = nil
            context = nil
            reachability = nil
            visitorId = nil
            config = nil
        }
        traitsLock.withLock { cachedTraits = [:] }
        userIdLock.withLock { userId = nil }
    }

    // MARK: - Internals

    private func enqueue(_ type: String,
                         merging base: [String: Any],
                         with extras: [String: Any])
    {
        guard let queue = self.queue else {
            ripplesLog("SDK not initialized — call Ripples.setup() before sending events. Dropping '\(type)' call.")
            return
        }
        // Merge user properties first, then system fields on top so $-prefixed
        // keys can never be overwritten by user-supplied properties.
        var props = extras
        for (k, v) in base { props[k] = v }

        // Inject persistent visitor ID.
        if props["$visitor_id"] == nil, let vid = visitorId {
            props["$visitor_id"] = vid
        }

        // Inject persistent user ID if the host app has identified the user.
        if props["$user_id"] == nil {
            if let uid = userIdLock.withLock({ userId }) {
                props["$user_id"] = uid
            }
        }

        // Inject session ID and device context.
        if let ctx = context {
            if props["$session_id"] == nil {
                props["$session_id"] = ctx.sessionId
            }
            for (k, v) in ctx.device where props[k] == nil {
                props[k] = v
            }
            let dyn = ctx.dynamic(networkType: reachability?.networkType)
            for (k, v) in dyn where props[k] == nil {
                props[k] = v
            }
            // TODO(db): these flags (is_testflight, is_emulator, is_sideloaded,
            // is_mac_catalyst, is_ios_on_mac, app_build) are sent but not yet
            // persisted server-side — add columns when dashboards need them.
            for (k, v) in ctx.extras where props[k] == nil {
                props[k] = v
            }
        }

        queue.add(RipplesEvent(type: type, properties: props))
    }

    private func registerLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default

        // Mark background time for session expiry tracking; also flush the queue.
        let backgroundToken = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.context?.didEnterBackground()
            self?.flush()
        }

        // Rotate session if the app was backgrounded long enough.
        let foregroundToken = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.context?.didBecomeActive() }

        let terminateToken = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }

        lifecycleObservers = [backgroundToken, foregroundToken, terminateToken]
        #endif
    }
}
