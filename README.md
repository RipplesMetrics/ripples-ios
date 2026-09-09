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
