# Logitech HID++ protocol gates

MouseKy uses no virtual mouse. Pointer movement, scrolling and primary buttons
continue to travel directly from the physical Logitech mouse to macOS.

## Supported runtime paths

- HID++ `0x8110`: Logitech G-Series runtime button filter and spy events.
- HID++ `0x1B04`: temporary diversion for compatible Logitech MX controls.

Neither path writes onboard flash during application changes. Devices without
one of these features remain visible but cannot be remapped.

## 0x8110 acceptance gate

Feature function 4 is reverse-engineered and must be verified per device:

1. Read and retain the complete original runtime remapping table.
2. Filter exactly one non-primary button and read the table back.
3. Verify one complete spy down/up pair and no native duplicate action.
4. Restore the original table and verify it by read-back.
5. Repeat after sleep/wake and disconnect/reconnect.

Failure at any step keeps the device diagnostic-only.

## 0x1B04 acceptance gate

Only controls advertising the divertible capability are changed. MouseKy must
restore every original reporting state on stop and release any pressed shortcut
when the device disconnects.
