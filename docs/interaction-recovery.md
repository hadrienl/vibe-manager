# Recovery from failed agent interactions

An answer submitted through a conversation card, the request palette or the companion uses the
same `AnswerAgentRequest` service. In the application composition, delivery confirmation is enabled.
After the last key, the service waits up to three seconds for the request to settle through the
activity tracker or for two readings of the terminal to show that the dialog awaiting the final key has changed.
Earlier transitions between questions and their review do not count as delivery. Moving
the highlight alone does not confirm delivery. An unreadable terminal does not confirm it either.

For Claude questions with previews, the selected option must be visibly highlighted before Return
is written. Tall previews are recognized by their frame and Notes footer, rather than the distance
between the last numbered choice and the bottom of the screen.

If the dialog cannot be read or identified (`notOnScreen`, `otherDialog`), or an answer cannot be
completed/confirmed (`interrupted`), the app opens the affected session in terminal view. It leaves
the request pending and never automatically retries input. A request already settled elsewhere is
not treated as a bug.

If the user turned on **Settings › Notifications › Problem Reports › Report failed answers on
GitHub** (off by default), the same failure queues a **public** GitHub issue in
`hadrienl/vibe-manager`, labelled `bug`, opened under the user's own GitHub account. Turned off,
nothing is written to the outbox and nothing waiting in it is sent. The report includes the
request content, selected answer, planned and successfully written key groups, terminal text
before/after, timestamp, app build, OS and recovery behavior. Common credential forms (including
AWS environment variables, Basic/Bearer authorization, `*_TOKEN` variables, passwords in URLs,
GitHub, GitLab, Slack and Google keys, JWTs and private keys) and the user name in `/Users/<name>`
are masked; a typed or pasted text is reported by its length only, in the selected answer and in
key traces, and taken out of the terminal text where it shows whole. The terminal text and request content are included so a maintainer can reproduce the
case without an image. Each block is cut at 9,000 characters and the body at 60,000, within
GitHub's limit.

`InteractionFailureReporter` stores its outbox under `logs/interaction-failures` in the app's data
directory. It uses the installed `gh` CLI and its existing GitHub authentication. A failed
submission is retried after a minute, the delay doubling up to an hour, and pending entries are
retried on app launch. A report is given up after 10 failed attempts or 3 days, so a missing or
signed-out `gh` is not run forever. At most 3 issues are opened in 24 hours; the others wait.
Pending reports from older versions are sanitized again before they are submitted. Each request has a stable
SHA-256 fingerprint: an existing local result or a matching GitHub issue prevents another post,
including after a crash between issue creation and saving its URL. Completed entries retain the
issue URL in their JSON file. Network/API failures do not delay the terminal fallback.

Regression case: [#558](https://github.com/hadrienl/vibe-manager/issues/558), Claude Code 2.1.326,
Parcourses “Liens #120”, a single-choice question with a preview taller than the option list.
