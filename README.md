# QuickTranslate (OCR + Google) for iOS 15–17.0 (rootless / ElleKit)

## What it does
- Floating 🌐 button in whitelisted apps.
- Tap 🌐 → pick mode → tap on text anywhere → screenshot ROI → Vision OCR → Google Translate → popup with Copy/Close.

## Requirements
- iOS 15.0 – 17.0
- rootless jailbreak with ElleKit (nathanlr)
- PreferenceLoader
- AltList (com.opa334.altlist)

## Google Translate setup (official API)
This uses **Google Cloud Translation API v2**.
1) Create a Google Cloud project.
2) Enable "Cloud Translation API".
3) Create an API key.
4) Paste the key into Settings → QuickTranslate → Google Translate → API Key.

Notes:
- The selected text (OCR result) is sent to Google for translation.
- Costs may apply depending on your Google Cloud plan.

## Build (Theos)
Rootless build:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless
```

Install the resulting .deb and respring.

## Settings / prefs domain
Domain: `1.com.quicktranslate.prefsfixed`
Keys:
- enabled (bool)
- useWhitelist (bool)
- whitelist (AltList multi-select)
- googleApiKey (string)
- targetLang (string, default `de`)
- largeROI (bool)
