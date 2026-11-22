fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios simulator

```sh
[bundle exec] fastlane ios simulator
```



### ios test

```sh
[bundle exec] fastlane ios test
```



### ios testflight_preflight

```sh
[bundle exec] fastlane ios testflight_preflight
```



### ios prepare_bundle_ids

```sh
[bundle exec] fastlane ios prepare_bundle_ids
```



### ios release_archive

```sh
[bundle exec] fastlane ios release_archive
```



### ios testflight_status

```sh
[bundle exec] fastlane ios testflight_status
```



### ios beta

```sh
[bundle exec] fastlane ios beta
```



### ios retry_testflight_upload

```sh
[bundle exec] fastlane ios retry_testflight_upload
```



### ios appstore_prepare

```sh
[bundle exec] fastlane ios appstore_prepare
```

App-Store-Metadaten, eindeutige Screenshots, Build und Preisstufe 1 vorbereiten

### ios appstore_submit

```sh
[bundle exec] fastlane ios appstore_submit
```

Den aktuell vorbereiteten Build bei Apple zur Prüfung einreichen

### ios appstore_privacy

```sh
[bundle exec] fastlane ios appstore_privacy
```

App-Datenschutz mit der sicher im macOS-Schlüsselbund hinterlegten Apple-Anmeldung veröffentlichen

### ios appstore_cancel_review

```sh
[bundle exec] fastlane ios appstore_cancel_review
```

Eine laufende App-Store-Prüfung abbrechen, damit der aktuelle Build eingereicht werden kann

### ios appstore_release

```sh
[bundle exec] fastlane ios appstore_release
```

App Store vollständig vorbereiten, Datenschutz veröffentlichen und zur Prüfung einreichen

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
