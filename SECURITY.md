# Security policy

This policy covers the Payriff iOS SDK and the example app in this repository.

## Report a vulnerability

Report security problems privately, through GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem and submit the form.

The report is private: only you and the people who maintain this repository can see it. You can follow up with them in the report itself.

Do not open a public issue, pull request or discussion for a security problem. Do not share the details anywhere else until a fix is released.

## Supported versions

| Version | Supported |
|---|---|
| The latest 1.x release | Yes |
| Any older release | No |

Security fixes ship in a new 1.x release. Update to the latest 1.x release to get them.

## What to include

- The SDK version (`Payriff.version`), the Xcode version, and the iOS version of the device or simulator.
- What the problem is, and what an attacker could do with it.
- The steps to reproduce it. A small sample project or a code snippet helps most.
- Logs or screenshots, if they help. Remove keys, client secrets and card data from them first.

Never send real card numbers, secret keys or customer data. Use test cards and test orders.
