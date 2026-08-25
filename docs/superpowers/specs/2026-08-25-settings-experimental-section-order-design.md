# Settings Experimental Section Order

## Goal

Keep everyday KelvinXDR settings first and place the complete experimental Space Layout
Protection surface at the very bottom of the Settings window.

## Design

The Settings window remains a single vertical, scrollable stack. Its sections appear in this
order:

1. Levels
2. Shortcuts
3. HDR trigger corner
4. Pause the boost for these apps, including its explanation, app list, and Add/Remove buttons
5. Space Layout Protection — Experimental, including every existing warning, preference,
   profile control, restore action, and conversion action

A separator remains between the app-pause section and the experimental section. No Space
Layout Protection behavior, persistence, safety gate, or menu-bar visibility changes.

## Verification

The Settings UI test will verify that the experimental heading appears after the app-pause
heading in the arranged-view order. The complete strict hardware-free test suite and strict app
build must pass before the updated application is installed and relaunched.
