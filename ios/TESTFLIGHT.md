# Installing FreeFlow on an iPhone with TestFlight

FreeFlow's iOS app and keyboard reach your iPhone through TestFlight internal
testing. GitHub Actions builds, signs and uploads each build, so installing
one never needs a Mac. The one-time setup below happens in a browser and on
the iPhone. After it, a new build takes one command, one approval click, and
an Update tap in TestFlight.

The workflow is `.github/workflows/ios-testflight.yml`. AGENTS.md treats it as
high risk because it signs builds and uploads them with an App Store Connect
API key. Read [Security](#security) before you create the key.

Checked against Apple's and GitHub's documentation on 2026-11-20. Apple
renames buttons now and then. When a label here doesn't match, the linked
Apple page has the current one.

## How it works

Each run has two jobs.

1. Archive builds the app and keyboard for devices in Release, with an ad-hoc
   signature, and checks the result. It has no access to the API key, so the
   branch's build, including any Run Script phase or build setting, can't
   reach the key.
2. Sign and upload waits for your approval, then downloads that archive,
   checks it again, signs it with your team's cloud-managed Apple
   Distribution certificate, checks the signed app, and uploads it. It runs
   nothing from the branch except the workflow, the
   `.github/scripts/ios-testflight-*.sh` scripts and
   `ios/Config/ExportOptions-TestFlight.plist`.

## Identifiers

| What | Value |
|---|---|
| App bundle ID | `dev.karim.freeflow` |
| Keyboard bundle ID | `dev.karim.freeflow.keyboard` |
| App Group | `group.dev.karim.freeflow` |
| Keychain access group | `<TEAM ID>.dev.karim.freeflow.shared` |

Bundle IDs and App Groups are unique across all Apple developer accounts. If
Apple says one is taken, pick another prefix and use it everywhere below,
including the `FREEFLOW_BUNDLE_ID_PREFIX` variable.

You need:

- A paid Apple Developer Program membership. An individual member is the
  Account Holder, the only role that can request API access.
- Your Team ID, the 10-character code under Membership details at
  <https://developer.apple.com/account>.
- Admin access to the GitHub repository.
- An iPhone with iOS 17 or later, FreeFlow's deployment target.

## One-time setup

Do these in order. Profiles made before the App Group is assigned stop
working when you assign it, and the workflow can't run before step 5.

### 1. Register the App Group

1. Open Certificates, Identifiers & Profiles at
   <https://developer.apple.com/account/resources/identifiers/list>.
2. Click Identifiers in the sidebar, then the add button (+).
3. Select App Groups and click Continue.
4. Description: `FreeFlow`. Identifier: `group.dev.karim.freeflow`.
5. Click Continue, then Register.

### 2. Register the two App IDs

First the app:

1. In Identifiers, click the add button (+), select App IDs, and click
   Continue.
2. App is already selected as the type. Click Continue.
3. Description: `FreeFlow`. Select Explicit and enter the bundle ID
   `dev.karim.freeflow`.
4. Under Capabilities, select App Groups. Leave the rest alone.
5. Click Continue, then Register.

You can't pick the group while registering. Assign it afterwards:

6. In the identifiers list, click `dev.karim.freeflow`.
7. In the App Groups row, click Configure. In App Group Assignment, select
   `group.dev.karim.freeflow`, click Continue, then Assign.
8. Click Save at the top right and confirm the warning about provisioning
   profiles.

Repeat steps 1 to 8 for the keyboard, with description `FreeFlow Keyboard`
and bundle ID `dev.karim.freeflow.keyboard`, and assign it the same group.
Keep descriptions to letters, digits and spaces. The portal rejects some
punctuation there, so don't paste a bundle ID into one.

Keychain Sharing has no App ID setting. It is an Xcode capability, and App
Store profiles allow every keychain group that starts with your Team ID, so
`<TEAM ID>.dev.karim.freeflow.shared` needs nothing here. The workflow's IPA
check confirms that each profile allows it.

The workflow can't do this step. The export may create provisioning profiles,
but it never registers App IDs or changes their capabilities, and the App
Store Connect API has no way to create an App Group or assign one.

### 3. Create the app record

App Store Connect only lets the Account Holder add apps after accepting the
latest agreement. If it asks, accept it under Business first.

1. Open <https://appstoreconnect.apple.com/apps>.
2. Click the add button (+), then New App.
3. Fill in the form:
   - Platforms: iOS.
   - Name: `FreeFlow Keyboard Dev`. Names are 2 to 30 characters, and one app
     per language can use a name, so if this one is taken, try `FreeFlow
     Dictation Dev` or add your name. Testers see it in TestFlight. The home
     screen shows "FreeFlow", which comes from the app.
   - Primary Language: English (U.S.).
   - Bundle ID: `dev.karim.freeflow`, listed with the description from step 2.
     The keyboard ships inside the app and gets no record of its own.
   - SKU: `freeflow-ios`. Only you see it, and it can't change later.
   - User Access: Full Access.
4. Click Create.

The API can't create app records, so uploads fail until this exists.

### 4. Create a Team API key

1. In App Store Connect, open Users and Access from the top navigation, then
   the Integrations tab. App Store Connect API is selected.
2. The first time, click Request Access, agree to the terms, and click
   Submit. Apple reviews requests one at a time, so access may not be
   instant.
3. Under Team Keys, click Generate API Key. If a key exists already, click
   the add button (+) instead.
4. Name: `GitHub TestFlight`. Access: Admin. Click Generate.
5. Click Download API Key next to the new key. You get `AuthKey_<KEY ID>.p8`,
   and Apple lets you download it only once. Leave it in your Downloads
   folder for now, outside any clone of the repository.
6. Copy the Issuer ID near the top of the page, and the Key ID from the key's
   row.

Why Admin. The export signs with a cloud-managed Apple Distribution
certificate: Apple holds the private key and signs on request, so no signing
key ever sits on the runner. It also creates and renews the two App Store
provisioning profiles. Cloud signing works only with an Admin key. An App
Manager or Developer key gets "error: exportArchive: Cloud signing permission
error" at the export step, and the key form has no setting to change that.
You can't change a key's role later either. Revoke it and make a new one.

What it costs. An Admin key can do anything an Admin can do in App Store
Connect, for every app on your team, including adding and deleting users.
You can't limit it to one app.

The alternative is local signing. You'd create an Apple Distribution
certificate and two App Store profiles, one per App ID, by hand in the
portal, then store the certificate's `.p12` and the profiles as secrets. The
workflow would import them into a temporary keychain and sign manually, and
the API key would only upload, which reports say an App Manager key can do.
The trade is a long-lived signing key on CI instead of a powerful API key,
plus a certificate to renew every year and profiles to rebuild whenever an
App ID changes. This workflow doesn't implement that mode.

### 5. Set up the GitHub environment and variables

Don't start a real run before this step. A run that names a missing
environment makes GitHub create it with no protection. If `testflight`
already exists, check its rules in step 3 below before you add any secret.

1. On GitHub, open the repository's Settings, then Environments, then New
   environment.
2. Name it `testflight` and click Configure environment.
3. Select Required reviewers and add yourself. Leave Prevent self-review
   unchecked, or you can't approve your own runs. Click Save protection
   rules, and check that the page now lists you as a required reviewer.
4. Under Deployment branches and tags, choose Selected branches and tags. Add
   a rule with the exact name of each branch you will upload from, such as
   `main`. See [Security](#security) before you allow a branch that agents
   push to.
5. Under Environment secrets, add these three:

   | Secret | Value |
   |---|---|
   | `APP_STORE_CONNECT_API_KEY_P8` | The whole text of `AuthKey_<KEY ID>.p8`, BEGIN and END lines included. Base64 of the file works too. |
   | `APP_STORE_CONNECT_KEY_ID` | The Key ID, 10 characters. |
   | `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID, a UUID. |

6. Open Settings, then Secrets and variables, then Actions, then the
   Variables tab. Add these as repository variables, not environment
   variables, because the archive job has no environment:

   | Variable | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Your Team ID. |
   | `FREEFLOW_BUNDLE_ID_PREFIX` | `dev.karim.freeflow` |
   | `FREEFLOW_BUILD_NUMBER_OFFSET` | Optional. See [Build numbers](#build-numbers). |

Keep the three secrets in the environment only. GitHub hands repository
secrets to every workflow on every branch, without approval, and a job in
the environment would read a repository copy without complaint. So the
workflow stops if it can see any of them as a repository secret.

The same with the GitHub CLI, once steps 1 to 4 of this list are done. The
environment must exist before `gh secret set --env` can write to it.

```sh
gh secret set APP_STORE_CONNECT_API_KEY_P8 --repo some-du6e/freeflow-ios --env testflight < ~/Downloads/AuthKey_<KEY ID>.p8
gh secret set APP_STORE_CONNECT_KEY_ID --repo some-du6e/freeflow-ios --env testflight --body '<KEY ID>'
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo some-du6e/freeflow-ios --env testflight --body '<ISSUER ID>'
gh variable set APPLE_TEAM_ID --repo some-du6e/freeflow-ios --body '<TEAM ID>'
gh variable set FREEFLOW_BUNDLE_ID_PREFIX --repo some-du6e/freeflow-ios --body dev.karim.freeflow
```

Don't paste the `.p8` at gh's interactive prompt. It reads one line only.

Once the secret is saved, keep the `.p8` in a password manager or delete it.
GitHub never shows secret values again. Never copy it into a clone of this
repository, which is public.

### 6. Set up internal testing

1. In App Store Connect, open the app, then the TestFlight tab.
2. Click the add button (+) next to Internal Testing in the sidebar.
3. In Create New Internal Group, name the group `Me` and keep Enable
   automatic distribution selected. Click Create.
4. Select the group, click Invite Testers, select yourself under App Store
   Connect Users, and click Add.

Internal testers are App Store Connect users with the Account Holder, Admin,
App Manager, Developer or Marketing role, up to 100 per app. Internal builds
need no App Review and no test information. Apple describes automatic
distribution for builds uploaded from Xcode, so check that the first build
from CI shows up in the group. If it doesn't, open the group and use Add
Builds.

### 7. Install TestFlight on the iPhone

Install TestFlight from the App Store. It needs iOS 16 or later. When your
first build is ready for the group, Apple emails you an invitation. Open it
on the iPhone, tap View in TestFlight, then Accept and Install.

Accept it while the iPhone is signed in to the Apple Account you will keep
using. TestFlight ties the invitation to the first account that accepts it,
and undoing that means removing and re-inviting yourself.

## Uploading a build

1. Start the workflow on the branch to build:

   ```sh
   gh workflow run ios-testflight.yml --repo some-du6e/freeflow-ios --ref <branch>
   ```

   The branch must contain this workflow and be one of the environment's
   deployment branches. The Actions tab shows a Run workflow button only for
   workflow files on the default branch, so until this one reaches `main`,
   start it with `gh`. Don't delete all of this workflow's runs before then:
   GitHub may forget the workflow, and `gh` then answers that it isn't on the
   default branch.

2. The Archive job runs first, in a few minutes, plus any wait for a free
   macOS runner. Then the run page shows a review request. Click Review
   deployments, select `testflight`, and click Approve and deploy. A run
   that nobody approves fails after 30 days.
3. The signing job then signs, checks and uploads the build.
4. App Store Connect then processes the build. Apple emails you when
   processing starts and when it completes or fails. Apple gives no typical
   time and says a build still processing after 24 hours has a problem. The
   TestFlight tab's Build Uploads list shows the status.
5. On the first upload, check that the build shows the Internal marker under
   its build number. That marker is what keeps it away from external testers
   and App Review. If it's missing, expire the build in TestFlight and tell
   whoever maintains this workflow.
6. On the iPhone, open TestFlight and tap Install, or Update for later builds.
7. The first time, open FreeFlow and finish its setup, including the
   microphone permission. Then add the keyboard in Settings, General,
   Keyboard, Keyboards, Add New Keyboard, FreeFlow. Tap FreeFlow in that list
   and turn on Allow Full Access.

TestFlight builds expire 90 days after upload.

### Build numbers

Each upload of a version needs a higher build number than the last one. The
workflow uses its run number plus `FREEFLOW_BUILD_NUMBER_OFFSET`, which
defaults to 0. A re-run of the same run gets `<number>.<attempt>`, such as
`7.2`, which sorts between 7 and 8.

If App Store Connect says the build number must be higher, for example after
an upload from Xcode used a bigger number, set `FREEFLOW_BUILD_NUMBER_OFFSET`
to that number. Every later run builds above it. An upload that failed
doesn't use up its number.

The version string, now 0.1.0, is `MARKETING_VERSION` in
`ios/Config/FreeFlow.xcconfig`. Build numbers may start over when it goes up.

### Dry run

```sh
gh workflow run ios-testflight.yml --repo some-du6e/freeflow-ios --ref <branch> -f dry_run=true
```

A dry run archives with a made-up team, `ABCDE12345`, checks the archive,
passes it to the signing job, and checks it again there. It uses no secrets
and no environment, so it needs no approval and uploads nothing. It catches
Release-only compile errors and broken entitlements before you spend an
approval, and it works before any of the setup above.

## What the workflow checks

Each job stops at the first failed step, and the upload runs only after every
check before it passes.

| Job | Step | Fails when |
|---|---|---|
| Archive | Check the settings | An App Store Connect secret exists at repository level, a variable is missing or malformed, or `FREEFLOW_BUILD_NUMBER_OFFSET` isn't a whole number. The error names the value. |
| Archive | Archive with an ad-hoc signature | Release doesn't compile for a device. Warnings count as errors. |
| Archive | Check the archive's identifiers and entitlements | See the list below. |
| Sign and upload | Check the testflight environment's settings | A secret is missing or malformed, or the environment sets one of the variables to a different value. |
| Sign and upload | Unpack the archive | The downloaded archive differs from the one the archive job packed. |
| Sign and upload | Check the archive's identifiers and entitlements | The same checks again, on the archive as received. |
| Sign and upload | Write the export options | `ios/Config/ExportOptions-TestFlight.plist` no longer describes an internal-only App Store Connect export. |
| Sign and upload | Install the App Store Connect API key | The `.p8` secret isn't a readable private key. |
| Sign and upload | Export and sign for App Store Connect | Apple rejected the key, refused to sign, or couldn't make the profiles. See [Troubleshooting](#troubleshooting). |
| Sign and upload | Check the signed IPA before upload | The App Store signature lacks something iOS needs, listed below. |
| Sign and upload | Upload to TestFlight | altool reports a failed upload, even when it exits with status 0. |

The archive checks cover both the app and the keyboard:

- The bundle IDs are `dev.karim.freeflow` and `dev.karim.freeflow.keyboard`,
  both bundles have the run's build number, and their version strings match.
- The Info.plists and the signature carry `group.dev.karim.freeflow` and
  `<TEAM ID>.dev.karim.freeflow.shared`, with no `FAKETEAMID`.
- The app declares `ITSAppUsesNonExemptEncryption` as false, and the keyboard
  is a keyboard extension.

The IPA check adds, for both bundles:

- `com.apple.security.application-groups` contains `group.dev.karim.freeflow`.
  Without it, the keyboard can't read the app's settings and history.
- `keychain-access-groups` contains `<TEAM ID>.dev.karim.freeflow.shared`.
  Without it, the keyboard can't read the API key from the shared keychain.
- `FAKETEAMID` appears nowhere. Xcode writes that placeholder when nothing
  supplies a team prefix, and no iPhone grants a keychain group built from
  it.
- `get-task-allow` is false. App Store Connect rejects debuggable builds.
- The application identifiers are `<TEAM ID>.<bundle ID>`, and the signature
  and profiles belong to your team.
- Each bundle embeds an App Store profile, one without a device list, that
  allows the App Group and the keychain group. iOS refuses to install an app
  whose signature claims more than its profile allows.

The archive gets an ad-hoc signature, so CI never creates an Apple
Development certificate on your account. Automatic signing on a fresh runner
makes a new one every run, and teams have hit Apple's certificate limit that
way.

## Troubleshooting

"App Store Connect secret at repository level". One of the three secrets
also exists under the repository's Actions secrets. Delete that copy and keep
the one in the environment.

"Set the repository variable ...", or "The testflight environment has no
secret ...". The value is missing or misspelled, or it sits at the wrong
level. Secrets go in the environment, variables in the repository.

The signing job fails before asking for approval, with an error that the
branch may not deploy to `testflight`. Add the branch to the environment's
deployment branches, or run from a branch that is listed.

"Cloud signing permission error" during export. The API key isn't an Admin
key. Generate an Admin key and replace the three secrets.

An export or upload error about authentication, or HTTP 401. The Key ID,
Issuer ID and `.p8` secrets don't belong together, or the key was revoked.
The export checks the key first, so this usually shows up there.

An export error that no profile matches `dev.karim.freeflow`, or that the
profile lacks the App Groups capability or the
`com.apple.security.application-groups` entitlement. One of the App IDs is
missing, lacks App Groups, or doesn't have `group.dev.karim.freeflow`
assigned. Fix step 2 and run again. The export makes fresh profiles.

"the embedded profile does not allow 'group.dev.karim.freeflow'". The same
cause, for the bundle the message names.

An export error that no "iOS Distribution" or "Apple Distribution"
certificate was found, with an Admin key and both App IDs set up. Xcode took
the manual-signing path for the ad-hoc archive. Tell whoever maintains the
workflow, since `.github/scripts/ios-testflight-archive.sh` then has to stop
passing `CODE_SIGN_STYLE=Manual`.

"PLA Update available" or a similar agreement error. Apple updated the
Program License Agreement. Accept it at <https://developer.apple.com/account>
and run again.

An upload error that no app record matches, or that the Apple ID can't be
found from the bundle ID. The app record from step 3 is missing, or its
bundle ID differs from `FREEFLOW_BUNDLE_ID_PREFIX`.

"The bundle version must be higher than the previously uploaded version".
Set `FREEFLOW_BUILD_NUMBER_OFFSET` to the number in the message and run
again.

A build uploaded from Xcode says Missing Compliance. CI builds can't, because
the archive check requires `ITSAppUsesNonExemptEncryption`. Answer the
export compliance question on the build page.

The build processed but never reached your group. Add it with the group's
Add Builds button, and check that automatic distribution is on.

The keyboard shows "Open FreeFlow to allow the microphone", or never starts
recording. Open the FreeFlow app first and allow the microphone, since the
keyboard records under the app's permission. Then check that Allow Full
Access is on.

## Building from a Mac instead

Use this to debug the keyboard with Xcode's debugger and Console, or when CI
is down. You can't attach a debugger to a TestFlight build.

1. Install Xcode 26.6 or later. If the iPhone runs iOS 27, use Xcode 27.
2. In Xcode, open Settings, then Accounts, and add your Apple Account.
3. Copy `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig`,
   which git ignores. Set `DEVELOPMENT_TEAM` to your Team ID. Set
   `FREEFLOW_BUNDLE_ID_PREFIX` to `dev.karim.freeflow.debug` to keep the
   TestFlight install, or to `dev.karim.freeflow` to replace it. Signed in
   with your Apple Account, Xcode registers the `.debug` App IDs and App
   Group itself, and both keyboards are called FreeFlow in the keyboard list.
   Leave `FREEFLOW_KEYCHAIN_GROUP_PREFIX` unset, since Xcode fills it in from
   your profile.
4. Open `ios/FreeFlow.xcodeproj`, choose the FreeFlow scheme and your iPhone,
   and click Run. The first time, the iPhone asks you to turn on Developer
   Mode in Settings, then Privacy & Security, and restarts.

Don't choose a team in the Signing & Capabilities editor. Xcode writes it
into `project.pbxproj`, where it overrides `Local.xcconfig` and ends up in
commits.

To upload from the Mac, first set `FREEFLOW_BUNDLE_ID_PREFIX` back to
`dev.karim.freeflow`, the prefix with an app record. Then choose Product,
then Archive, then Distribute App, then TestFlight Internal Only. Afterwards,
set `FREEFLOW_BUILD_NUMBER_OFFSET` so that CI builds number above the one
Xcode used.

## Keeping it working

- From April 2027, App Store Connect accepts only builds made with the iOS 27
  SDK. Before then, move the workflow from Xcode 26.6 to Xcode 27. The
  deployment target stays iOS 17.
- The archive compiles in Release, which the simulator job in `ios.yml`
  doesn't. A dry run catches Release-only errors before an approval.
- A revoked API key breaks the export and the upload until the secrets hold a
  new key. A lapsed membership breaks them until you renew it.

## Security

- The API key, its Key ID and the Issuer ID live only in the `testflight`
  environment. Only the signing job reads them, and only after you approve
  the run. Pull requests, including ones from forks, never get them.
- The signing job runs only three things from the branch: the workflow, the
  `.github/scripts/ios-testflight-*.sh` scripts, and
  `ios/Config/ExportOptions-TestFlight.plist`. Before you approve a run on a
  branch you didn't write, read what changed in those files between the last
  run you approved and the commit the run page shows. Changes elsewhere,
  including the Xcode project, run in the archive job, which can't read the
  key.
- Approval is only as strong as your GitHub login. Anything that uses it,
  including AI agents on your machines, can start a run and approve it
  through the API, with no click from you. Allowing only branches that agents
  don't push to, such as a protected `main`, keeps such a run from getting
  the key. If you allow an agent's branch for a test, remove it afterwards.
- The repository is public, so its Actions logs are public. The workflow's
  own scripts print bundle IDs, your Team ID and entitlements, never your
  team name, certificate names or keys, and GitHub masks secret values. Apple's
  tools print their own errors, which can name your team or certificate. If
  one does, delete that run's logs from the run page.
- The job writes the key to the runner's temporary folder with mode 600 and
  deletes it at the end, even after a failure. GitHub-hosted runners are
  discarded after each job anyway.
- If the key leaks, revoke it in Users and Access, Integrations. It stops
  working at once. Then generate a new one and update the secrets.
- The export marks builds TestFlight internal only, so nobody can send them
  to external testers or App Review by mistake. The keyboard records through
  WebKit, a technique App Review might not accept.
- The app declares `ITSAppUsesNonExemptEncryption` as false because it only
  uses the HTTPS built into iOS. Adding a crypto library or custom encryption
  changes that answer. See Apple's export compliance page below.

## Sources

Apple:
- Register an App Group: <https://developer.apple.com/help/account/identifiers/register-an-app-group>
- Register an App ID: <https://developer.apple.com/help/account/identifiers/register-an-app-id>
- Enable app capabilities: <https://developer.apple.com/help/account/identifiers/enable-app-capabilities>
- Sharing access to keychain items: <https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps>
- TN3125, inside code signing provisioning profiles: <https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles>
- Add a new app: <https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app>
- App Store Connect API keys: <https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/> and <https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api>
- Cloud-managed certificates: <https://developer.apple.com/help/account/certificates/cloud-managed-certificates>
- Admin key needed for cloud signing: <https://developer.apple.com/forums/thread/698117>
- Add internal testers: <https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers>
- TestFlight for testers: <https://testflight.apple.com/>
- Upload builds: <https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds>
- View builds and processing: <https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata>
- CFBundleVersion: <https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion>
- Export compliance: <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>
- Upload requirements: <https://developer.apple.com/news/upcoming-requirements/?id=04282026a> and <https://developer.apple.com/news/?id=k1mtkt1k>
- altool: <https://keith.github.io/xcode-man-pages/altool.1.html>, a copy of Xcode's man page

GitHub:
- Managing environments for deployment: <https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments>
- Deployment branch and protection options: <https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments>
- Reviewing deployments: <https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments>
- Manually running a workflow: <https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow>
- Events that trigger workflows, workflow_dispatch: <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>
