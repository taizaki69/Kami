# Chapter notifications

In **Updates → Chapter notifications**, turn on **Notify about new chapters**
and Save. The default is off. Saving on requests iOS alert/sound permission
while Kami is active; no startup or background job requests permission. If
permission was denied, the panel links to iOS Settings and keeps your saved
choice. Manual and automatic checks use the same preference. Enabling automatic
checks alone does not enable notifications.

Each alert contains a count of saved chapters and opens the current Updates
list. Manga titles, chapter names and URLs are omitted from notification content.
The first successful chapter list for a manga establishes a silent baseline.
Already-started scans are excluded when notifications are enabled. Later
cancelled, failed or interrupted checks can still notify for chapters that
were committed before they stopped, with an incomplete-check message.

iOS controls delivery, Focus, sounds and previews. While Kami is in the
foreground, alerts go to the notification list without a banner or sound.
Turning the option off removes only Kami's chapter notifications; removal
cannot undo an alert already shown or sounded. A failed settings save is
reported: the previous durable choice can still apply after relaunch.

## Durable attempts and interruption

Schema 9 stores a single preference/revision, a scan-row watermark and the last
batch ID/count/outcome. Settings compare-and-save rejects stale editors and ABA
changes. A pass reads at most 100 scans in sequence and stops before a running
scan. It uses only durable non-baseline discoveries, advances empty scans, and
atomically claims the batch before calling iOS. Later passes can process any
remaining scans. No source/network request is made to compose an alert.

On recovery, an unfinished attempt is checked against pending and delivered
OS requests. If its identifier is present, the record becomes submitted. If
absent, the result is unconfirmed: it may never have been submitted, or may have
already appeared and been dismissed. Kami does not blindly submit it again.
Failed submissions also remain unconfirmed, without automatic replay. A crash
between claim and submission can therefore miss an alert. This favors avoiding
duplicate alerts; the chapters remain in Updates. Submitted means iOS accepted
the request, not proof that the user saw it. This is not exactly-once delivery.

AppModel retains its library-operation lease through the OS submission and
awaited cleanup. Cancellation drains a noncooperative platform callback;
disable/re-enable invalidates the old owner, and late completion removes that
specific old identifier. Storage uncertainty stops further local submissions
until settings are explicitly reloaded. The journal is not included in native
or Mihon backups and grants no source or extension authority. Any future scan
history pruning must preserve/rebase the monotonic watermark, together with
the existing fair-rotation sequence.

The notification delegate is installed before app launch returns. Default taps
on valid owned IDs create a bounded, in-memory navigation intent, consumed by
one active scene after an exclusive library operation ends. The scene opens a
fresh Updates navigation stack, without old manga/chapter IDs. Other windows
keep their own selected tabs. A later cold-launch callback can recreate the
intent; presentation selection is not persisted as a library mutation.

## Evidence and device checks

See [verification](VERIFICATION-2026-10-07-CHAPTER-NOTIFICATIONS.md) and the
implementation PR for actual test/build evidence. Fixtures use a fake OS center
and real SQLite where relevant; they do not send system alerts or contact sites.
On an Apple device, verify enable/deny/allow, return from Settings, Focus and
foreground presentation, tap from cold launch, two active windows, expired
background grants, disable during submission, termination at claim/submission,
and failure to open durable storage. Hosted reader-rendering tests do not prove
these notification or scene interactions.

Primary platform contracts: [permission](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)),
[early delegate registration](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate),
[local submission](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/add(_:withcompletionhandler:)),
[identifier replacement and repeated alerts](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:)),
and [pending removal](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removependingnotificationrequests(withidentifiers:)).
