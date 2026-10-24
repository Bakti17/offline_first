# offline_first_example

Demo app for the `offline_first` packages (see the repository root).

## What it shows

- **Cart** — auto-sync feature (`syncOnConnect: true` + 5-minute periodic interval)
- **Transactions** — manual-only feature, encrypted at rest (`secure: true`)
- Live `statusStream` binding (queue phases and counts)
- Buttons for `syncNow`, `syncAll`, `retryFailed`, `purgeSynced`

## Running

```sh
flutter pub get
flutter run
```

The app posts to `https://api.example.com` by default — point
`baseUrl` in [`lib/main.dart`](lib/main.dart) at your own backend (any
echoing 2xx endpoint works). Toggle airplane mode to watch the outbox
drain on reconnect.
