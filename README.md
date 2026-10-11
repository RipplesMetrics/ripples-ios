# Ripples iOS SDK

iOS / macOS / tvOS / watchOS client for [Ripples Metrics](https://ripples.sh).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/ripplesanalytics/ripples-ios", from: "0.1.6")
```

## Keys

Ripples projects have two identifiers:

| Key           | Format   | Where to use           | Scope                               |
|---------------|----------|------------------------|-------------------------------------|
| Secret key    | `priv_…` | Server-side only       | Full ingest access, incl. `revenue` |
| Project token | UUID     | iOS / web / any client | `track`, `identify`, `signup`, `pageview` only |

The iOS SDK takes the **project token**. It's safe to bundle: revenue events
from the token are rejected server-side, so a scraped key can't forge MRR / LTV.
Rotate in project settings if you see abuse.

**Never** ship the `priv_` key in a mobile or web app.

### Subscriptions, trials and auto-renew

There is no `subscription()` here, on purpose: a purchase is real only once
Apple says so, and the device's own "I bought it" is a claim. Report
subscription state from your server, from App Store Server Notifications, with
the [PHP](https://github.com/ripplesmetrics/ripples-php) or
[Python](https://github.com/ripplesmetrics/ripples-python) SDK. Send the whole
state on every notification: a free trial is `trialing` at its renewal price,
and auto-renew off is the live status with `renews: false` and
`period_ends_at`, not `canceled`, which means the subscription has ended. See
[Auto-renew off is not a cancel](https://ripples.sh/docs/php-sdk#subscription-renewal).

## Usage

Initialize once at app launch:

```swift
import Ripples

@main
struct MyApp: App {
    init() {
        Ripples.setup(RipplesConfig(projectToken: "YOUR-PROJECT-TOKEN"))
    }
}
```

### Identify a user

```swift
Ripples.shared.identify("user_123", traits: [
    "email": "jane@example.com",
    "name":  "Jane Smith",
])
```

### Track events

Call `track` **only** for significant product usage — actions that prove a user got real value (created a budget, sent a message, invited a teammate). This is **not** a generic event log like PostHog or Mixpanel: do not send screen views, banner impressions, button taps, or "viewed X" events. Every `track` call feeds the Activation dashboard, so noise here pollutes your funnel. (Use `screen(_:)` / `trackScreen` for navigation.)

Pass `area` to group actions into a product area (shown in the adoption dashboard):

```swift
Ripples.shared.track("created a budget", area: "budgets")

// Mark the activation moment
Ripples.shared.track("added transaction", area: "transactions", properties: [
    "activated": true,
])

// area can also be passed inside properties — both forms are equivalent
Ripples.shared.track("exported report", properties: ["area": "reports"])
```

#### Keeping user data fresh

Pass `userProperties` alongside any event to let the backend upsert the user
record without a separate `identify` call. This mirrors how PostHog handles
`$set` — one request carries both the event and the trait update:

```swift
Ripples.shared.track("created a budget",
                     area: "budgets",
                     userProperties: ["plan": "pro", "company": "Acme"])
```

Traits are also cached automatically from the last `identify()` call and
forwarded with every subsequent event, so you generally don't need to pass
`userProperties` explicitly — it's there for cases where you have fresh data
at event time. Pass an empty dictionary `[:]` to suppress forwarding for a
specific call.

### Milestones

A milestone is a moment in a person's lifecycle that you count **once per person**, date by when they first reached it, and attribute to how they were acquired. It is not product usage, so it never feeds activation, retention or "last seen" the way `track` does.

> Would you put it on a funnel next to *signed up* and *paid*, and count each person once? → `milestone`.
> Do people do it repeatedly as part of using the product? → `track`.

```swift
Ripples.shared.milestone("onboarding_completed", properties: ["steps": 4])
Ripples.shared.milestone("paywall_viewed", properties: ["placement": "settings"])
Ripples.shared.milestone("notifications_enabled")
```

- It belongs to this device's person: the identified user, or the anonymous visitor before `identify()` (merged on identify).
- Names are snake_case. Recommended for apps: `onboarding_completed`, `paywall_viewed`, `checkout_started`, `notifications_enabled`, `tracking_authorized`, `integration_connected`, `invite_sent`, `invite_accepted`, `email_verified`. Built-in moments (`signed_up`, `activated`, `first_paid`, …) and billing events (`payment_failed`, refunds, renewals) are refused; an invalid name is logged and dropped.
- Sending one again is fine. Reports count each person once, on the day of their first.
- Sales stages (`mql`, `sql`, `demo_held`) come from your server, through the PHP or Python SDK or `POST /v1/ingest/batch` with `{"$type": "milestone", "$name": "mql", "$user_id": "42"}`.

Docs: https://ripples.sh/docs/milestones

### Track screen views

Pass `area` to group screens with the same product area as your track calls:

```swift
Ripples.shared.screen("BudgetList", area: "budgets")
```

Use the SwiftUI modifier — one line per screen:

```swift
struct HomeView: View {
    var body: some View {
        List { ... }
            .trackScreen("Home")
    }
}

// With area and extra properties
struct ListDetailView: View {
    let listId: String
    var body: some View {
        ScrollView { ... }
            .trackScreen("ListDetail", properties: ["area": "lists", "list_id": listId])
    }
}
```

Or call it imperatively (e.g. UIKit or custom navigation):

```swift
Ripples.shared.screen("Settings")
Ripples.shared.screen("ListDetail", area: "lists", properties: ["list_id": listId])
```

Screen views are stored as `pageview` events and appear in the **Pages** report
alongside web pageviews. The first screen in each session is automatically
flagged as the session entry.

### Track companies (B2B)

Say which company (or workspace) the user works in. Every later event counts for it, across launches, until you call `group` with another id (the user switched workspace) or `resetGroup()`:

```swift
Ripples.shared.group(team.id, traits: ["name": team.name, "plan": "business"])

Ripples.shared.resetGroup()   // e.g. on logout
```

Use your own id for the company, never its name. Docs: https://ripples.sh/docs/companies

### Flush manually

```swift
// Before logout, account deletion, etc.
Ripples.shared.flush { /* delivery attempted */ }
```

## Automatic behaviour

| What                          | How                                                                 |
|-------------------------------|---------------------------------------------------------------------|
| **Persistent visitor ID**     | Generated once, stored to disk, survives reinstalls                 |
| **Session ID**                | New UUID on SDK init; rotates after 30 min in background            |
| **Device & OS metadata**      | Collected once at startup, merged into every event automatically    |
| **Geo / country**             | Resolved server-side from the request IP via Cloudflare headers     |
| **Offline queuing**           | Events persisted to disk; flushed when connectivity returns         |
| **Background flush**          | Queue flushed on `didEnterBackground` and `willTerminate`           |
| **Retry / backoff**           | 5xx / network errors back off exponentially (5s → 5 min)           |
| **Poison batch protection**   | Non-retryable 4xx drops the batch so a bad payload can't wedge the queue |

## Configuration

```swift
let config = RipplesConfig(projectToken: "YOUR-PROJECT-TOKEN")
config.host                 = "https://your-domain.com"  // self-hosted
config.flushIntervalSeconds = 30
config.flushAt              = 20
config.maxBatchSize         = 50
config.maxQueueSize         = 1000
config.requestTimeout       = 10
config.onError              = { error in print("Ripples error:", error) }
Ripples.setup(config)
```

## Requirements

* Swift 5.5+
* iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+

## License

MIT
