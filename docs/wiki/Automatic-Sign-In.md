# Automatic Sign-In

For PCs you reach only through RustDesk: after a restart they sign in by themselves, so the
keyboard/mouse program and your apps start.

## Turning it on

Installer > *Automatic sign-in* page, or Desk Console > **Automatic sign-in...** on that PC
(asks for admin once).

- **Existing account** -- e.g. your own. A local account is just its name (`Bob`, also `.\Bob`
  or `PCNAME\Bob`); a domain account is `DOMAIN\user`.
- **Dedicated local account** -- just a name (default `BuildRunner`). Created as a **standard
  user** with a non-expiring password, or its password reset if it exists. Keeps your own
  password off the PC.
- **Lock the screen right after** (recommended) -- a logon task locks the screen 20 s after an
  automatic sign-in. It only fires within 3 minutes of Windows starting, so a manual sign-in is
  left alone. RustDesk and Deskflow keep working at the lock screen.

## How the password is kept

- Stored in the **LSA secret `DefaultPassword`** -- the method Sysinternals Autologon uses --
  never in the plain-text `Winlogon\DefaultPassword` registry value.
- Checked with Windows (`LogonUser`) **before** anything changes: a typo changes nothing.
- *Only allow Windows Hello sign-in* hides automatic sign-in; setup turns it off, remembers
  the old value, and restores it when automatic sign-in is turned off.
- A new dedicated account's first sign-in would stop on the privacy-settings screen; setup
  sets the policy that skips it.

## Turning it off

Desk Console > **Automatic sign-in... > Turn off**, or the installer's *Turn off*. Removes the
LSA secret, the lock task, and restores the Windows Hello setting.

## When it does not sign in

- **A sign-in notice is set** (`LegalNoticeCaption`/`LegalNoticeText` policy): Windows shows it
  and waits for OK before signing in. Setup warns when it finds one. Clear it only if you know
  where it came from.
- **Fast Startup:** "Shut down" + power on is a resume, not a restart -- the lock task's
  "within 3 minutes of start" check may not fire. Use *Restart*.
- **Domain policy** may forbid automatic sign-in on domain-joined PCs.

## Trade-off

Anyone at the PC after a restart gets that account's desktop until the screen locks. Use the
lock option, prefer a dedicated standard account on PCs you do not sit at, and keep those PCs
somewhere you trust.
